defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any rolling `window_ms` (one minute
  by default). N per user is read once, at startup, from a JSON file:

      {"default": 60, "users": {"alice": 600, "bob": 10}}

  Users not listed in `users` get `default`.

  ## Starting

  Add it to the supervision tree, before the endpoint and job runners:

      # lib/my_app/application.ex
      children = [
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

  ## Calling

      case MyApp.RateLimiter.check(user.id) do
        {:ok, remaining} -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> reject(retry_after_ms)
      end

  All checks go through one process, which makes the check-and-record step
  atomic per user.
  """

  use GenServer

  @window_ms 60_000

  ## Client API

  def start_link(opts) do
    path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    window_ms = Keyword.get(opts, :window_ms, @window_ms)
    GenServer.start_link(__MODULE__, {path, window_ms}, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within its limit.

  Returns `{:ok, remaining}` or `{:error, {:rate_limited, retry_after_ms}}`.
  """
  @spec check(term(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl true
  def init({path, window_ms}) do
    %{"default" => default} = config = path |> File.read!() |> JSON.decode!()
    limits = Map.get(config, "users", %{})
    schedule_sweep(window_ms)

    {:ok, %{default: default, limits: limits, window_ms: window_ms, hits: %{}}}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, to_string(user_id), state.default)
    hits = state.hits |> Map.get(user_id, :queue.new()) |> drop_expired(now, state.window_ms)
    count = :queue.len(hits)

    if count < limit do
      hits = :queue.in(now, hits)
      {:reply, {:ok, limit - count - 1}, put_in(state.hits[user_id], hits)}
    else
      # limit 0 means nothing is ever allowed; there is no oldest hit to wait on
      retry_after =
        case :queue.peek(hits) do
          {:value, oldest} -> max(oldest + state.window_ms - now, 1)
          :empty -> state.window_ms
        end

      {:reply, {:error, {:rate_limited, retry_after}}, put_in(state.hits[user_id], hits)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      for {user, q} <- state.hits,
          q = drop_expired(q, now, state.window_ms),
          not :queue.is_empty(q),
          into: %{},
          do: {user, q}

    schedule_sweep(state.window_ms)
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp drop_expired(q, now, window_ms) do
    case :queue.peek(q) do
      {:value, t} when t <= now - window_ms -> q |> :queue.drop() |> drop_expired(now, window_ms)
      _ -> q
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Idle users' empty histories are swept once per window so the map can't grow forever.
  defp schedule_sweep(window_ms), do: Process.send_after(self(), :sweep, window_ms)
end

# Example callers (need Phoenix/Plug, so shown as comments):
#
#   defmodule MyAppWeb.Plugs.RateLimit do
#     import Plug.Conn
#
#     def init(opts), do: opts
#
#     def call(%{assigns: %{current_user: user}} = conn, _opts) do
#       case MyApp.RateLimiter.check(user.id) do
#         {:ok, _remaining} ->
#           conn
#
#         {:error, {:rate_limited, retry_after_ms}} ->
#           conn
#           |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
#           |> send_resp(429, "Too many requests")
#           |> halt()
#       end
#     end
#   end
#
#   # in a router pipeline:  plug MyAppWeb.Plugs.RateLimit
#
#   # in an Oban worker:
#   def perform(%Oban.Job{args: %{"user_id" => id}}) do
#     case MyApp.RateLimiter.check(id) do
#       {:ok, _} -> do_work(id)
#       {:error, {:rate_limited, ms}} -> {:snooze, max(div(ms, 1000), 1)}
#     end
#   end
