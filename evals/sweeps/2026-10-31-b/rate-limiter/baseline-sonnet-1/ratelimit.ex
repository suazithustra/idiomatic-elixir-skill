defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most `limit` calls in any trailing `window_ms`
  (default one minute). Limits are read once, when the process starts, from an
  Elixir script file that evaluates to a map of user id => limit:

      # config/rate_limits.exs
      %{
        "alice" => 120,
        "bob" => 10
      }

  Users not in the file get `:default_limit`.

  ## Starting it

  Add it to the application supervision tree, before the endpoint and any
  job runner that uses it:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         limits_path: Application.app_dir(:my_app, "priv/rate_limits.exs"),
         default_limit: 60},
        MyAppWeb.Endpoint
      ]

  If the file is missing or does not evaluate to a map of non-negative
  integers, the process fails to start, so a bad config stops the boot rather
  than silently allowing everything.

  ## Calling it

      case MyApp.RateLimiter.check(user.id) do
        {:ok, remaining} -> do_work(remaining)
        {:error, {:rate_limited, retry_after_ms}} -> reject(retry_after_ms)
      end

  `check/1` records a hit when it returns `:ok`; rejected calls are not
  recorded, so a blocked user regains access as soon as their oldest hit ages
  out.

  ### Controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            {:ok, _remaining} ->
              {:ok, report} = MyApp.Reports.generate(params)
              json(conn, report)

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", to_string(ceil(retry_after_ms / 1000)))
              |> send_resp(429, "Too many requests")
          end
        end
      end

  ### Background job (Oban)

      defmodule MyApp.Workers.SyncWorker do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            {:ok, _remaining} -> MyApp.Sync.run(user_id)
            {:error, {:rate_limited, retry_after_ms}} ->
              {:snooze, max(div(retry_after_ms, 1000), 1)}
          end
        end
      end

  ## Design notes

  All checks go through one GenServer, which makes check-and-record atomic
  without locks. That is fine for thousands of checks per second; if the
  limiter becomes a bottleneck, shard by `:erlang.phash2(user_id, n)` across
  several instances. State is in memory only and per node: limits reset on
  restart and are not shared across a cluster.
  """

  use GenServer

  @default_window_ms 60_000
  @default_limit 60
  @sweep_interval_ms 60_000

  @type user_id :: term()

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks and records one request for `user_id`.

  Returns `{:ok, remaining}` or `{:error, {:rate_limited, retry_after_ms}}`.
  """
  @spec check(user_id(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl GenServer
  def init(opts) do
    with {:ok, limits} <- load_limits(Keyword.fetch!(opts, :limits_path)) do
      schedule_sweep()

      {:ok,
       %{
         limits: limits,
         default_limit: Keyword.get(opts, :default_limit, @default_limit),
         window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
         # user_id => hit timestamps (monotonic ms), newest first
         hits: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_id, state.default_limit)
    recent = prune(Map.get(state.hits, user_id, []), now, state.window_ms)

    if length(recent) < limit do
      hits = Map.put(state.hits, user_id, [now | recent])
      {:reply, {:ok, limit - length(recent) - 1}, %{state | hits: hits}}
    else
      hits = Map.put(state.hits, user_id, recent)
      reply = {:error, {:rate_limited, retry_after(recent, now, state.window_ms)}}
      {:reply, reply, %{state | hits: hits}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      for {user_id, timestamps} <- state.hits,
          recent = prune(timestamps, now, state.window_ms),
          recent != [],
          into: %{},
          do: {user_id, recent}

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Timestamps are newest first, so everything after the first expired one
  # is expired too.
  defp prune(timestamps, now, window_ms) do
    Enum.take_while(timestamps, &(&1 > now - window_ms))
  end

  # A limit of 0 leaves `recent` empty; the caller must wait a full window.
  defp retry_after([], _now, window_ms), do: window_ms

  defp retry_after(recent, now, window_ms) do
    oldest = List.last(recent)
    max(oldest + window_ms - now, 1)
  end

  defp load_limits(path) do
    {limits, _binding} = Code.eval_file(path)

    if is_map(limits) and Enum.all?(limits, &valid_entry?/1) do
      {:ok, limits}
    else
      {:error, {:invalid_limits_file, path}}
    end
  rescue
    e in Code.LoadError -> {:error, {:limits_file_unreadable, path, e.reason}}
  end

  defp valid_entry?({_user_id, limit}), do: is_integer(limit) and limit >= 0
end
