defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter using a rolling (sliding) one-minute window.

  Each user may make at most N requests in any 60-second span. N comes from a
  config file read once when the limiter starts; users not listed in the file
  get `default_limit`.

  ## Config file

  An Elixir config script, for example `config/rate_limits.exs`:

      import Config

      config :rate_limiter,
        default_limit: 60,
        limits: %{
          "alice" => 120,
          "bob" => 10
        }

  User ids can be any term (strings, integers); they only need to match what
  callers pass to `check/1`.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job processes that call it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.exs")},
        MyAppWeb.Endpoint
      ]

  If the file is missing or invalid, the limiter fails to start, and so does
  the application.

  ## Calling it

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> reject(retry_after_ms)
      end

  A successful `check/1` counts as one request. All checks go through one
  process, so counts are exact. That is fine for thousands of checks per
  second; beyond that, shard by user id across several limiters.

  State is in memory only: a restart clears all counts.
  """

  use GenServer

  @window_ms 60_000

  ## Client API

  @doc """
  Starts the limiter. Options:

    * `:config_path` (required) - path to the limits file
    * `:name` - registered name, default `#{inspect(__MODULE__)}`
    * `:window_ms` - window length, default 60_000 (mainly for tests)
  """
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Records a request for `user_id` if it is under its limit.

  Returns `:ok`, or `{:error, {:rate_limited, retry_after_ms}}` when the user
  has used up its requests. Rejected requests are not counted.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    config = path |> Config.Reader.read!() |> Keyword.fetch!(:rate_limiter)
    window_ms = Keyword.get(opts, :window_ms, @window_ms)

    state = %{
      default_limit: Keyword.fetch!(config, :default_limit),
      limits: Keyword.get(config, :limits, %{}),
      window_ms: window_ms,
      hits: %{}
    }

    schedule_sweep(window_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_id, state.default_limit)

    queue =
      state.hits
      |> Map.get(user_id, :queue.new())
      |> drop_expired(now - state.window_ms)

    if :queue.len(queue) < limit do
      hits = Map.put(state.hits, user_id, :queue.in(now, queue))
      {:reply, :ok, %{state | hits: hits}}
    else
      {:value, oldest} = :queue.peek(queue)
      retry_after = max(oldest + state.window_ms - now, 1)
      hits = Map.put(state.hits, user_id, queue)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: hits}}
    end
  end

  # Forget users with no hits in the current window so memory does not grow
  # with the number of users ever seen.
  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.window_ms

    hits =
      for {user_id, queue} <- state.hits,
          queue = drop_expired(queue, cutoff),
          not :queue.is_empty(queue),
          into: %{},
          do: {user_id, queue}

    schedule_sweep(state.window_ms)
    {:noreply, %{state | hits: hits}}
  end

  defp drop_expired(queue, cutoff) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= cutoff -> queue |> :queue.drop() |> drop_expired(cutoff)
      _ -> queue
    end
  end

  defp schedule_sweep(window_ms), do: Process.send_after(self(), :sweep, window_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end

# Example callers (need Phoenix, so shown as comments).
#
# Controller, as a plug:
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
#           {:error, {:rate_limited, retry_after_ms}} ->
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
# Background job (Oban worker):
#
#     defmodule MyApp.Workers.SendReport do
#       use Oban.Worker
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok -> MyApp.Reports.send(user_id)
#           {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
#         end
#       end
#     end
