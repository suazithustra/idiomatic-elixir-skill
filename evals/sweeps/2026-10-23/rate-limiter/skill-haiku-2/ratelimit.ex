defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling 60-second window.

  N comes from a JSON file read once, when the limiter starts. The file gives
  a `"default"` limit for users not listed, and a `"users"` map from user ID
  to limit:

      {
        "default": 60,
        "users": {"42": 300, "77": 10}
      }

  User IDs are integers or strings. An integer ID is compared with the file's
  string keys, so `42` and `"42"` are the same user.

  ## Starting it

  Add it to your supervision tree with the path to the limits file:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  ## Checking it

  Call `check/2` before doing work. It returns `:ok` or `{:error, :rate_limited}`.

  A controller:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              json(conn, Reports.generate(params))

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  A background job:

      def run_export(user_id, params) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> Exports.run(user_id, params)
          {:error, :rate_limited} -> {:error, :rate_limited}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path to the JSON limits file. Required. The file is
      read here, so a missing or malformed file stops the start.
    * `:name` - the registered name, which is also the name of the ETS table
      that holds the request log. Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records one request for `user_id` and reports whether it is within the limit.

  Returns `:ok` when the user has made no more than N requests in the last
  minute, counting this one. Otherwise returns `{:error, :rate_limited}`, and
  the refused request is not counted.

  The check runs in the caller's process and uses ETS directly, so callers do
  not queue behind each other. The cost is that a refused request is briefly
  in the log while it is being checked, so a concurrent request can be refused
  a little early. The limit itself is never exceeded.
  """
  def check(name \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, make_ref()}
    :ets.insert(name, {key})

    if count_in_window(name, user_id, now) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    :persistent_term.put({__MODULE__, name}, read_limits!(config_path))

    table_options = [:named_table, :public, :ordered_set, read_concurrency: true]
    :ets.new(name, table_options)

    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:"$1", :"$2", :_}}, [{:<, :"$2", cutoff}], [true]}])

    schedule_sweep()
    {:noreply, name}
  end

  defp count_in_window(name, user_id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, to_string(user_id), limits.default)
  end

  defp read_limits!(config_path) do
    %{"default" => default, "users" => users} =
      config_path
      |> File.read!()
      |> JSON.decode!()

    %{default: default, users: users}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end
end
