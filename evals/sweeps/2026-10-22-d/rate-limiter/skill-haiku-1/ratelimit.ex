defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling minute.

  Limits come from a JSON file read when the limiter starts:

      {
        "default": 60,
        "users": {
          "42": 300,
          "97": 10
        }
      }

  `"default"` applies to every user not listed under `"users"`. User IDs are
  compared by their string form, so the keys in the file are strings and an
  integer ID such as `42` matches `"42"`.

  ## Starting

  Add the limiter to the supervision tree:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  Without `:config_path`, the path is read from
  `config :my_app, rate_limits_path: ...`. A missing or malformed file makes
  the limiter fail to start, so the application does not boot without limits.

  ## Checking

  `check/2` is a plain function that runs in the caller's process and does not
  message the limiter. Controllers, jobs, and other processes call it directly:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case MyApp.RateLimiter.check(user.id) do
            :ok ->
              json(conn, Reports.generate(user, params))

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  Background jobs use the same `case` and decide for themselves whether to
  run the work, retry later, or drop it.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(10)

  @doc """
  Starts the limiter.

  ## Options

    * `:name` - the registered name, which is also the name of its ETS table.
      Defaults to `MyApp.RateLimiter`. Tests pass their own name.
    * `:config_path` - the JSON file with the limits. Defaults to
      `Application.fetch_env!(:my_app, :rate_limits_path)`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.get_lazy(opts, :config_path, &default_config_path/0)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id`. Returns `:ok` if the user is within their
  limit for the last minute, or `{:error, :rate_limited}` if not.

  A rejected request is removed again, so it does not count against the user.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    id = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    key = {id, now, System.unique_integer([:monotonic])}

    # Insert before counting, so concurrent checks see this request. Counting
    # first would let two processes both read a count under the limit.
    :ets.insert(name, {key, nil})

    if requests_in_window(name, id, now) <= limit_for(name, id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    case read_limits(config_path) do
      {:ok, limits} ->
        create_table(name, limits)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp default_config_path do
    Application.fetch_env!(:my_app, :rate_limits_path)
  end

  defp create_table(name, limits) do
    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    :ets.insert(name, limits)
  end

  defp requests_in_window(name, id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{id, :"$1", :_}, :_}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, id) do
    case :ets.lookup(name, {:limit, id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default, 2)
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp read_limits(path) do
    case File.read(path) do
      {:ok, contents} -> decode_limits(contents)
      {:error, reason} -> {:error, {:unreadable_config, path, reason}}
    end
  end

  defp decode_limits(contents) do
    case JSON.decode(contents) do
      {:ok, config} -> parse_limits(config)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default, "users" => users} = config) when is_map(users) do
    limits = [{:default, default} | Enum.map(users, fn {id, limit} -> {{:limit, id}, limit} end)]

    if Enum.all?(limits, fn {_key, limit} -> positive_integer?(limit) end) do
      {:ok, limits}
    else
      {:error, {:invalid_config, config}}
    end
  end

  defp parse_limits(config), do: {:error, {:invalid_config, config}}

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
