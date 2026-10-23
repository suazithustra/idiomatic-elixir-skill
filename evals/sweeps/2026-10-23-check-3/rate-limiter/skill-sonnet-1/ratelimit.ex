defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any
  rolling 60 seconds.

  N comes from a JSON file read once when the limiter starts:

      {"default": 60, "users": {"42": 600, "17": 10}}

  `"default"` applies to every user not listed under `"users"`. User ids are
  matched as strings, so integer id `42` uses the `"42"` entry. If the file
  is missing or invalid, the limiter does not start.

  Requests are stored in a public ETS (Erlang Term Storage) table owned by
  this process. `check/2` runs in the caller's process, so callers never
  queue behind the GenServer. It inserts a row for the request, counts the
  user's rows from the last minute, and deletes its own row if the count is
  over the limit. Rejected requests therefore do not count against the user.
  Under a burst of concurrent requests at the limit, several may be rejected
  together, but the limit is never exceeded.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job runner that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  and in `config/runtime.exs`:

      config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.generate(params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      def perform(%{"user_id" => user_id}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Exports.run(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_microseconds :timer.minutes(1) * 1000
  @default_sweep_interval :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - the process name, also the name of its ETS table. Defaults
      to `#{inspect(__MODULE__)}`.
    * `:sweep_interval` - milliseconds between removals of expired request
      rows. Defaults to one minute.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    defaults = [:config_path, name: __MODULE__, sweep_interval: @default_sweep_interval]
    opts = Keyword.validate!(opts, defaults)
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, config_path, opts[:sweep_interval]}, name: name)
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the
  user's limit, or `{:error, :rate_limited}` if it is not.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) when is_binary(user_id) or is_integer(user_id) do
    limit = limit_for(name, user_id)
    now = System.monotonic_time(:microsecond)
    row_key = {user_id, now, make_ref()}

    :ets.insert(name, {row_key})

    if count_since(name, user_id, now - @window_microseconds) <= limit do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path, sweep_interval}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        table_options = [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ]

        :ets.new(name, table_options)
        :ets.insert(name, limit_rows(limits))

        Process.send_after(self(), :sweep, sweep_interval)
        {:ok, %{name: name, sweep_interval: sweep_interval}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    delete_expired(state.name)
    Process.send_after(self(), :sweep, state.sweep_interval)
    {:noreply, state}
  end

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, to_string(user_id)}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, {:limit, :default}, 2)
    end
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp delete_expired(name) do
    cutoff = System.monotonic_time(:microsecond) - @window_microseconds
    match_spec = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, match_spec)
  end

  defp limit_rows(limits) do
    user_rows = Enum.map(limits.users, fn {user_id, limit} -> {{:limit, user_id}, limit} end)
    [{{:limit, :default}, limits.default} | user_rows]
  end

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = config) do
    with {:ok, default} <- validate_limit(default),
         {:ok, users} <- parse_users(Map.get(config, "users", %{})) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_config), do: {:error, :missing_default}

  defp parse_users(users) when is_map(users) do
    case Enum.find(users, fn {_user_id, limit} -> invalid_limit?(limit) end) do
      nil -> {:ok, users}
      {user_id, limit} -> {:error, {:invalid_limit, user_id, limit}}
    end
  end

  defp parse_users(other), do: {:error, {:invalid_users, other}}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp validate_limit(other), do: {:error, {:invalid_limit, :default, other}}

  defp invalid_limit?(limit), do: not (is_integer(limit) and limit > 0)
end
