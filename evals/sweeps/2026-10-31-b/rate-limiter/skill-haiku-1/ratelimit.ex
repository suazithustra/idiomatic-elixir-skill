defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a fixed number of requests in any rolling one-minute window.

  Limits come from a JSON file read once when the limiter starts:

      {
        "default_limit": 60,
        "limits": {"42": 300, "7": 10}
      }

  `default_limit` applies to every user not listed in `limits`. User IDs are
  matched as strings, so the key `"42"` applies to user ID `42`.

  Callers run `check/2` in their own process. The check reads and writes a
  public ETS table, so callers do not queue behind one process. The owning
  GenServer creates the table, loads the limits, and deletes expired entries.

  ## Starting it

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Trade-off

  Two requests that arrive at the same moment can both be rejected when only
  one of them would fit under the limit. A rejected request is removed again,
  so it never counts against the user, and the limit is never exceeded.

  ## Example caller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              report = Reports.create_report(conn.assigns.current_user, params)
              json(conn, %{id: report.id})

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  Background jobs call `check/2` the same way and skip or reschedule the work
  when it returns `{:error, :rate_limited}`.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(10)
  @table_options [
    :named_table,
    :public,
    :ordered_set,
    read_concurrency: true,
    write_concurrency: true
  ]

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path to the JSON limits file. Required. The file is read
      once, here. A missing or malformed file stops the start.
    * `:name` - the registered name, also used as the ETS table name. Defaults
      to the module name.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Counts one request for `user_id` and returns `:ok` if it is within the limit.

  Returns `{:error, :rate_limited}` when the user has already made the limit's
  worth of requests in the last minute. The rejected request is not counted.
  """
  @spec check(GenServer.name(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    limit = limit_for(name, user)
    now = System.monotonic_time(:millisecond)

    # The unique integer keeps two requests in the same millisecond apart.
    key = {user, now, System.unique_integer([:positive, :monotonic])}

    # Insert before counting. Admitted requests stay in the table, so each one
    # sees every earlier admitted request when it counts.
    :ets.insert(name, {key})

    if count_in_window(name, user, now) > limit do
      :ets.delete(name, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    :ets.new(name, @table_options)
    load_limits!(name, config_path)
    schedule_sweep()

    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()

    {:noreply, name}
  end

  defp limit_for(name, user) do
    default = :ets.lookup_element(name, {:limit, :default}, 2)
    :ets.lookup_element(name, {:limit, user}, 2, default)
  end

  defp count_in_window(name, user, now) do
    window_start = now - @window_ms
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", window_start}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp load_limits!(name, config_path) do
    %{"default_limit" => default_limit, "limits" => limits} =
      config_path
      |> File.read!()
      |> JSON.decode!()

    valid? = valid_limit?(default_limit) and Enum.all?(Map.values(limits), &valid_limit?/1)

    if not valid? do
      raise ArgumentError, "invalid rate limit file: #{config_path}"
    end

    limit_rows = for {user, limit} <- limits, do: {{:limit, user}, limit}
    :ets.insert(name, [{{:limit, :default}, default_limit} | limit_rows])
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end
