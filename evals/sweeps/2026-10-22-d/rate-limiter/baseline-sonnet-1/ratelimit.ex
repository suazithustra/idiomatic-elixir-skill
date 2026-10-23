defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any rolling `window` (one minute by
  default). N per user is read once, when the limiter starts, from a config
  file that evaluates to a map of the form:

      # priv/rate_limits.exs
      %{
        default: 60,
        users: %{"alice" => 120, "bob" => 10}
      }

  Users not listed under `:users` get the `:default` limit.

  State lives in a single GenServer, so checks are serialized and the limit
  can never be exceeded by concurrent callers. Controllers and background jobs
  just call `check/1`.

  ## Starting

  Add it to the application's supervision tree, before the endpoint and any
  job processors that use it:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.exs")},
        MyAppWeb.Endpoint
      ]

  ## Calling

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: term()

  ## Client API

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the limits file
    * `:window_ms` - length of the rolling window, default `#{@window_ms}`
    * `:name` - registered name, default `#{inspect(__MODULE__)}`
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within their limit.

  Returns `:ok` when the request is allowed, or
  `{:error, {:rate_limited, retry_after_ms}}` when it is not. A rejected
  request is not counted.
  """
  @spec check(user_id(), GenServer.server()) ::
          :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  @doc "Returns the limit that applies to `user_id`."
  @spec limit(user_id(), GenServer.server()) :: non_neg_integer()
  def limit(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:limit, user_id})
  end

  ## Server

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)

    state = %{
      window_ms: Keyword.get(opts, :window_ms, @window_ms),
      limits: load_limits!(path),
      # user_id => request timestamps (monotonic ms), newest first
      hits: %{}
    }

    schedule_sweep()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = limit_for(state.limits, user_id)
    recent = prune(Map.get(state.hits, user_id, []), now - state.window_ms)

    if length(recent) < limit do
      {:reply, :ok, put_in(state.hits[user_id], [now | recent])}
    else
      # Allowed again once the oldest request in the window expires.
      retry_after = List.last(recent, now) + state.window_ms - now
      {:reply, {:error, {:rate_limited, max(retry_after, 1)}}, put_in(state.hits[user_id], recent)}
    end
  end

  def handle_call({:limit, user_id}, _from, state) do
    {:reply, limit_for(state.limits, user_id), state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.window_ms

    hits =
      for {user_id, stamps} <- state.hits,
          recent = prune(stamps, cutoff),
          recent != [],
          into: %{},
          do: {user_id, recent}

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp load_limits!(path) do
    {config, _bindings} = Code.eval_file(path)
    default = Map.fetch!(config, :default)
    users = Map.get(config, :users, %{})

    unless valid_limit?(default) and Enum.all?(users, fn {_, n} -> valid_limit?(n) end) do
      raise ArgumentError, "invalid rate limits in #{path}: limits must be non-negative integers"
    end

    %{default: default, users: users}
  end

  defp valid_limit?(n), do: is_integer(n) and n >= 0

  defp limit_for(%{default: default, users: users}, user_id), do: Map.get(users, user_id, default)

  # Timestamps are newest first, so everything after the first stale one is stale too.
  defp prune(stamps, cutoff), do: Enum.take_while(stamps, &(&1 > cutoff))

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

# Example callers (not compiled here: they need Phoenix / Oban).
#
# defmodule MyAppWeb.ReportController do
#   use MyAppWeb, :controller
#
#   def create(conn, params) do
#     case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
#       :ok ->
#         json(conn, MyApp.Reports.generate(params))
#
#       {:error, {:rate_limited, retry_after_ms}} ->
#         conn
#         |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
#         |> put_status(:too_many_requests)
#         |> json(%{error: "rate limit exceeded"})
#     end
#   end
# end
#
# defmodule MyApp.Workers.Export do
#   use Oban.Worker
#
#   @impl Oban.Worker
#   def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#     case MyApp.RateLimiter.check(user_id) do
#       :ok -> MyApp.Exports.run(user_id)
#       {:error, {:rate_limited, ms}} -> {:snooze, max(div(ms, 1000), 1)}
#     end
#   end
# end
