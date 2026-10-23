defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute.

  N comes from a config file read once, when the limiter starts. The file is an
  Elixir script that returns a map, with a `:default` limit and optional
  per-user overrides:

      # priv/rate_limits.exs
      %{
        default: 60,
        users: %{"user-42" => 600, "user-7" => 10}
      }

  Every request is recorded as its own row in a public ETS table, so callers
  check the limit from their own process and never queue behind a single
  process. The owning GenServer only creates the table and sweeps expired rows.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and any
  job processor that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.exs")},
        MyAppWeb.Endpoint
      ]

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              report = MyApp.Reports.generate!(params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      def perform(%{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Exports.run(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(30)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and loads its limits from the config file.

  ## Options

    * `:config_path` - path of the limits file. Required.
    * `:name` - name of the limiter and of its ETS table. Defaults to
      `MyApp.RateLimiter`.
    * `:sweep_interval` - milliseconds between sweeps of expired requests.
      Defaults to 30 seconds.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [:config_path, name: __MODULE__, sweep_interval: @sweep_interval])

    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Records a request by `user_id` and reports whether it is within the user's
  limit.

  A rejected request is not counted against the user. User IDs must be
  binaries or integers.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    now = now_ms()
    request_key = {user_id, now, System.unique_integer([:monotonic])}

    # Insert first, then count: concurrent callers can never all observe room
    # for one more request, so the limit is never exceeded.
    true = :ets.insert(name, {request_key})

    if count_since(name, user_id, now - @window_ms) > limit_for(name, user_id) do
      :ets.delete(name, request_key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    config = load_config!(opts[:config_path])
    name = opts[:name]

    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    :persistent_term.put({__MODULE__, name}, config)
    schedule_sweep(opts[:sweep_interval])

    {:ok, %{name: name, sweep_interval: opts[:sweep_interval]}}
  end

  @impl true
  def handle_info(:sweep, state) do
    expired = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", now_ms() - @window_ms}], [true]}]
    :ets.select_delete(state.name, expired)
    schedule_sweep(state.sweep_interval)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.name})
  end

  defp count_since(name, user_id, cutoff) do
    recent = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, recent)
  end

  defp limit_for(name, user_id) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user_id, default)
  end

  defp load_config!(path) do
    {config, _bindings} = Code.eval_file(path)

    case config do
      %{default: default} when is_integer(default) and default >= 0 ->
        %{default: default, users: Map.get(config, :users, %{})}

      other ->
        raise ArgumentError,
              "#{path} must return a map with an integer :default limit, got: #{inspect(other)}"
    end
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp now_ms, do: System.system_time(:millisecond)
end
