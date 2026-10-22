defmodule MyApp.RateLimiter do
  @moduledoc ~S"""
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  Every allowed request is recorded as one row in a public ETS table owned by this
  process. `check/2` runs in the caller's process, so callers never queue behind
  the owner. A request is inserted first, then the user's rows inside the window
  are counted, and the row is deleted again when the count is over the limit. No
  step reads a value and writes one computed from it, so concurrent callers cannot
  overshoot the limit. When two callers race at the limit, both may be denied, but
  never both admitted.

  ## Configuration file

  The limits file is read once, when the limiter starts. It holds a single Erlang
  term, a map with a default limit and per-user overrides keyed by the same id
  callers pass to `check/2`:

      #{default => 60, users => #{42 => 600, 7 => 10}}.

  The path is the `:limits_file` option, which the application reads from
  runtime configuration:

      # config/runtime.exs
      config :my_app, MyApp.RateLimiter, limits_file: "priv/rate_limits.config"

  ## Starting it

  Add it to the supervision tree before anything that calls it:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, Application.fetch_env!(:my_app, MyApp.RateLimiter)},
        MyAppWeb.Endpoint
      ]

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              report = MyApp.Reports.create_report(params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.SyncWorker do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Sync.run(user_id)
            {:error, :rate_limited} -> {:snooze, 60}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:limits_file` - path of the limits file. Required.
    * `:name` - name of the process and its ETS table. Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` unless the user already made their limit of
  requests in the last minute.

  A denied request is not recorded, so it does not extend the wait.
  """
  @spec check(term(), atom()) :: :ok | {:error, :rate_limited}
  def check(user_id, name \\ __MODULE__) do
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, :erlang.unique_integer([:monotonic])}
    :ets.insert(name, {key})

    if requests_in_window(name, user_id, now) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    limits = load_limits!(Keyword.fetch!(opts, :limits_file))

    :ets.new(name, [
      :named_table,
      :public,
      :ordered_set,
      write_concurrency: true
    ])

    :persistent_term.put({__MODULE__, name}, limits)
    schedule_sweep()

    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()

    {:noreply, name}
  end

  defp requests_in_window(name, user_id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user_id, default)
  end

  defp load_limits!(path) do
    {:ok, [%{default: default, users: users} = limits]} = :file.consult(path)

    true = is_integer(default) and default > 0
    true = Enum.all?(users, fn {_user_id, limit} -> is_integer(limit) and limit > 0 end)

    limits
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
