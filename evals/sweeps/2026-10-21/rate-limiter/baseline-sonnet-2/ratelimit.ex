defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: at most N requests per rolling minute.

  N per user is read once, at startup, from an Erlang-term file containing a
  single map of user id to limit, ending in a period:

      %% config/rate_limits.terms
      \#{"alice" => 120, "bob" => 10}.

  Users not in the file get the `:default_limit`.

  All checks go through one process, so the check-and-record step is atomic
  across all callers (controllers, background jobs).

  ## Starting

  Add it to the supervision tree in `MyApp.Application`:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: "config/rate_limits.terms", default_limit: 60},
        MyAppWeb.Endpoint
      ]

  ## Using

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Client API

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within its limit.

  Returns `:ok`, or `{:error, {:rate_limited, retry_after_ms}}` where
  `retry_after_ms` is how long until the oldest counted request leaves the window.
  Rejected requests are not counted.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    default_limit = Keyword.get(opts, :default_limit, 60)

    case load_limits(path) do
      {:ok, limits} ->
        schedule_sweep()
        {:ok, %{limits: limits, default_limit: default_limit, hits: %{}}}

      {:error, reason} ->
        {:stop, {:bad_rate_limit_config, path, reason}}
    end
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits, user_id, state.default_limit)
    recent = prune(Map.get(state.hits, user_id, :queue.new()), now)

    if :queue.len(recent) < limit do
      hits = Map.put(state.hits, user_id, :queue.in(now, recent))
      {:reply, :ok, %{state | hits: hits}}
    else
      retry_after =
        case :queue.peek(recent) do
          {:value, oldest} -> max(oldest + @window_ms - now, 1)
          :empty -> @window_ms
        end

      hits = Map.put(state.hits, user_id, recent)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: hits}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    hits =
      state.hits
      |> Map.new(fn {user, q} -> {user, prune(q, now)} end)
      |> Map.reject(fn {_user, q} -> :queue.is_empty(q) end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  # Timestamps are in insertion order, so expired ones are at the front.
  defp prune(queue, now) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= now - @window_ms -> queue |> :queue.drop() |> prune(now)
      _ -> queue
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_limits(path) do
    with {:ok, [limits]} when is_map(limits) <- :file.consult(path),
         true <- Enum.all?(limits, fn {_, n} -> is_integer(n) and n >= 0 end) do
      {:ok, limits}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_format}
    end
  end
end

# Example callers. Not compiled here: they need Phoenix / Oban.
#
# Controller pipeline plug:
#
# defmodule MyAppWeb.Plugs.RateLimit do
#   import Plug.Conn
#
#   def init(opts), do: opts
#
#   def call(conn, _opts) do
#     user = conn.assigns.current_user
#
#     case MyApp.RateLimiter.check(user.id) do
#       :ok ->
#         conn
#
#       {:error, {:rate_limited, retry_after_ms}} ->
#         conn
#         |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
#         |> send_resp(429, "Too many requests")
#         |> halt()
#     end
#   end
# end
#
# Background job (Oban worker):
#
#   def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#     case MyApp.RateLimiter.check(user_id) do
#       :ok -> do_work(user_id)
#       {:error, {:rate_limited, ms}} -> {:snooze, max(div(ms, 1000), 1)}
#     end
#   end
