defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any trailing 60 seconds. N comes
  from a config file read once when the limiter starts. The file is an Elixir
  term file evaluating to a map (it is trusted, deploy-time configuration):

      # priv/rate_limits.exs
      %{
        default: 60,
        users: %{
          "alice" => 120,
          42 => 10
        }
      }

  Users not listed in `users` get `default`.

  All checks go through a single GenServer, so check-and-record is atomic
  no matter how many controllers or jobs call it concurrently.

  ## Starting

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and job processors that depend on it:

      children = [
        {MyApp.RateLimiter, path: Application.app_dir(:my_app, "priv/rate_limits.exs")},
        MyAppWeb.Endpoint
      ]

  ## Calling

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, :rate_limited, retry_after_ms} -> ...
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Client API

  @doc """
  Starts the limiter. Options:

    * `:path` (required) - config file to read
    * `:name` - registered name, defaults to `MyApp.RateLimiter`
  """
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, path, name: name)
  end

  @doc """
  Records a request for `user_id` if they are under their limit.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` when the user
  has exhausted their allowance. A rejected request is not recorded.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, :rate_limited, pos_integer()}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl GenServer
  def init(path) do
    {config, _bindings} = Code.eval_file(path)
    %{default: default} = config

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{default: default, limits: Map.get(config, :users, %{}), hits: %{}}}
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_id, state.default)
    hits = state.hits |> Map.get(user_id, :queue.new()) |> drop_expired(now)

    if :queue.len(hits) < limit do
      {:reply, :ok, put_hits(state, user_id, :queue.in(now, hits))}
    else
      {:value, oldest} = :queue.peek(hits)
      retry_after = max(oldest + @window_ms - now, 1)
      {:reply, {:error, :rate_limited, retry_after}, put_hits(state, user_id, hits)}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      for {user, queue} <- state.hits,
          queue = drop_expired(queue, now),
          not :queue.is_empty(queue),
          into: %{},
          do: {user, queue}

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, %{state | hits: hits}}
  end

  defp put_hits(state, user_id, hits), do: %{state | hits: Map.put(state.hits, user_id, hits)}

  defp drop_expired(queue, now) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= now - @window_ms -> queue |> :queue.drop() |> drop_expired(now)
      _ -> queue
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

# ---------------------------------------------------------------------------
# Example callers (need Phoenix/Oban; illustrative, not compiled)
# ---------------------------------------------------------------------------

# A plug usable from any controller or router pipeline:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(conn, _opts) do
#         case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
#           :ok ->
#             conn
#
#           {:error, :rate_limited, retry_after_ms} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
#             |> send_resp(429, "Too many requests")
#             |> halt()
#         end
#       end
#     end
#
#     # in a controller: plug MyAppWeb.Plugs.RateLimit
#
# A background job (Oban):
#
#     defmodule MyApp.Workers.Export do
#       use Oban.Worker
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok -> MyApp.Exports.run(user_id)
#           {:error, :rate_limited, retry_after_ms} -> {:snooze, div(retry_after_ms, 1000) + 1}
#         end
#       end
#     end
