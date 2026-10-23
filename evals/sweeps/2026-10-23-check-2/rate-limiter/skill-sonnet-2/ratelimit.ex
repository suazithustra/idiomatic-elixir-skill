defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"42": 600, "7": 10}}

  `"default"` applies to users not listed under `"users"`. User ids are matched
  as strings, so `42` and `"42"` are the same user.

  Callers check the limiter from their own process. A GenServer owns the ETS
  (Erlang Term Storage) table and sweeps old entries, but checks never go
  through it, so it is not a bottleneck.

  ## Starting it

  Add it to the application's supervision tree, before the endpoint and any
  job runner that calls it:

      children = [
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  The path is read at runtime, for example from `config/runtime.exs`:

      config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

  If the file is missing or invalid, the limiter fails to start, which stops
  the application at boot.

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            {:ok, _remaining} ->
              # ... do the work
              send_resp(conn, 202, "")

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
              |> send_resp(429, "rate limit exceeded")
          end
        end
      end

  ## Calling it from a background job

      def perform(%{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          {:ok, _remaining} -> do_work(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - registered name, also the name of the ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `{:ok, remaining}` with the number of requests left in the current
  minute, or `{:error, {:rate_limited, retry_after_ms}}` when the limit is
  reached. A rejected request is not counted.
  """
  @spec check(atom(), user_id()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    limit = limit_for(name, user)

    # Insert first, then count: each step is atomic on its own, so concurrent
    # callers cannot overwrite each other's entries the way a read-modify-write
    # of a timestamp list would.
    request_key = {:request, user, now, make_ref()}
    :ets.insert(name, {request_key})

    case count_since(name, user, now - @window_ms) do
      count when count <= limit ->
        {:ok, limit - count}

      count ->
        :ets.delete(name, request_key)
        {:error, {:rate_limited, retry_after(name, user, now, count - 1, limit)}}
    end
  end

  @impl true
  def init({name, config_path}) do
    limits = load_limits!(config_path)

    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    :ets.insert(name, {:default_limit, limits.default})
    Enum.each(limits.users, fn {user, limit} -> :ets.insert(name, {{:limit, user}, limit}) end)

    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]

    :ets.select_delete(name, match_spec)
    schedule_sweep()
    {:noreply, name}
  end

  defp load_limits!(config_path) do
    %{"default" => default} = decoded = config_path |> File.read!() |> JSON.decode!()

    users = Map.get(decoded, "users", %{})

    for limit <- [default | Map.values(users)], not (is_integer(limit) and limit >= 0) do
      raise ArgumentError,
            "limits in #{config_path} must be non-negative integers, got: #{inspect(limit)}"
    end

    %{default: default, users: users}
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp count_since(name, user, cutoff) do
    match_spec = [{{{:request, user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  # The user can send again once enough of their oldest requests leave the window
  # for the count to drop back to `limit - 1`.
  defp retry_after(name, user, now, recorded, limit) do
    match_spec = [{{{:request, user, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]

    timestamps = name |> :ets.select(match_spec) |> Enum.sort()
    expiring = Enum.at(timestamps, recorded - limit, now)

    max(expiring + @window_ms - now, 1)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
