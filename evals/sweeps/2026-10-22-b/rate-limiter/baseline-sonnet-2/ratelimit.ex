defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most `N` requests in any trailing `window_ms`
  (one minute by default). `N` is looked up per user from a limits file
  that is read once, when the limiter starts.

  ## Limits file

  An Erlang terms file (one `{user_id, limit}.` tuple per line), read with
  `:file.consult/1`. The special key `:default` applies to users not listed:

      {default, 60}.
      {"user-42", 600}.
      {"free-tier-user", 10}.

  ## Starting it

  Add it to the application's supervision tree, before the endpoint and
  any job processors that call it:

      children = [
        {MyApp.RateLimiter, limits_file: Application.app_dir(:my_app, "priv/rate_limits.terms")},
        MyAppWeb.Endpoint
      ]

  ## Using it

      case MyApp.RateLimiter.check(user_id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end

  Calls are serialized through one process, so concurrent callers can never
  collectively exceed a user's limit.
  """

  use GenServer

  @default_window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: term()
  @type result :: :ok | {:error, {:rate_limited, retry_after_ms :: pos_integer()}}

  ## Client API

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Records a request for `user_id` if they are under their limit.

  Returns `:ok` when allowed, or `{:error, {:rate_limited, retry_after_ms}}`
  with the time until the oldest counted request leaves the window.
  Rejected requests are not counted.
  """
  @spec check(user_id(), GenServer.server()) :: result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :limits_file)

    state = %{
      limits: load_limits!(path),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      # user_id => {count, :queue of monotonic-ms timestamps, oldest first}
      hits: %{}
    }

    schedule_sweep()
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = limit_for(state.limits, user_id)
    cutoff = now - state.window_ms

    {count, queue} = state.hits |> Map.get(user_id, {0, :queue.new()}) |> expire(cutoff)

    if count < limit do
      hits = Map.put(state.hits, user_id, {count + 1, :queue.in(now, queue)})
      {:reply, :ok, %{state | hits: hits}}
    else
      # limit == 0 leaves the queue empty; retry never succeeds, report a full window.
      retry_after =
        case :queue.peek(queue) do
          {:value, oldest} -> oldest + state.window_ms - now
          :empty -> state.window_ms
        end

      hits = Map.put(state.hits, user_id, {count, queue})
      {:reply, {:error, {:rate_limited, max(retry_after, 1)}}, %{state | hits: hits}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.window_ms

    hits =
      for {user_id, entry} <- state.hits,
          {count, _queue} = pair = expire(entry, cutoff),
          count > 0,
          into: %{},
          do: {user_id, pair}

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp expire({count, queue}, cutoff) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= cutoff -> expire({count - 1, :queue.drop(queue)}, cutoff)
      _ -> {count, queue}
    end
  end

  defp limit_for(limits, user_id) do
    case limits do
      %{^user_id => limit} -> limit
      %{default: limit} -> limit
    end
  end

  defp load_limits!(path) do
    entries =
      case :file.consult(String.to_charlist(path)) do
        {:ok, entries} -> entries
        {:error, reason} -> raise "cannot read rate limits from #{path}: #{inspect(reason)}"
      end

    limits =
      Map.new(entries, fn
        {key, limit} when is_integer(limit) and limit >= 0 -> {key, limit}
        other -> raise ArgumentError, "invalid rate limit entry in #{path}: #{inspect(other)}"
      end)

    unless Map.has_key?(limits, :default) do
      raise ArgumentError, "#{path} must define a {default, N}. entry"
    end

    limits
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

# ---------------------------------------------------------------------------
# Example callers (Phoenix is not a dependency of this file, so these are
# shown as comments).
#
# Supervision tree, lib/my_app/application.ex:
#
#     children = [
#       MyApp.Repo,
#       {MyApp.RateLimiter,
#        limits_file: Application.app_dir(:my_app, "priv/rate_limits.terms")},
#       MyAppWeb.Endpoint
#     ]
#     Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
#
# Controller, via a plug:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#       def init(opts), do: opts
#
#       def call(%{assigns: %{current_user: user}} = conn, _opts) do
#         case MyApp.RateLimiter.check(user.id) do
#           :ok ->
#             conn
#
#           {:error, {:rate_limited, retry_ms}} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_ms + 999, 1000)))
#             |> send_resp(429, "Too many requests")
#             |> halt()
#         end
#       end
#     end
#
#     # in a controller: plug MyAppWeb.Plugs.RateLimit
#
# Background job (e.g. Oban):
#
#     def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#       case MyApp.RateLimiter.check(user_id) do
#         :ok -> MyApp.Reports.generate(user_id)
#         {:error, {:rate_limited, retry_ms}} -> {:snooze, max(div(retry_ms, 1000), 1)}
#       end
#     end
# ---------------------------------------------------------------------------
