defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any trailing `window_ms`
  (default one minute). N per user is read once, at startup, from a config
  file of Erlang terms containing a single `{default_limit, user_limits}` tuple:

      {60, \#{<<"alice">> => 120, <<"bob">> => 10}}.

  User ids are looked up as given (strings in the example above). Users not
  listed get `default_limit`.

  All checks go through one GenServer, which makes check-and-record atomic.

  ## Starting

  Add to the application's supervision tree, before the endpoint and any
  job runners that use it:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.terms")},
        MyAppWeb.Endpoint
      ]

  ## Usage

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> ...
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Client API

  @doc """
  Options:

    * `:config_path` (required) - file with the limits
    * `:window_ms` - rolling window length, default #{@window_ms}
    * `:name` - registered name, default `#{inspect(__MODULE__)}`
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within its limit.

  Returns `:ok`, or `{:error, {:rate_limited, retry_after_ms}}` (in which case
  nothing is recorded).
  """
  def check(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    {default, overrides} = load_config!(path)

    state = %{
      default: default,
      overrides: overrides,
      window_ms: Keyword.get(opts, :window_ms, @window_ms),
      # user_id => timestamps (monotonic ms), newest first
      hits: %{}
    }

    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.overrides, user_id, state.default)
    recent = prune(Map.get(state.hits, user_id, []), now - state.window_ms)

    if length(recent) < limit do
      {:reply, :ok, put_in(state.hits[user_id], [now | recent])}
    else
      # The oldest hit in the window is the first to expire.
      retry_after =
        case List.last(recent) do
          nil -> state.window_ms
          oldest -> oldest + state.window_ms - now
        end

      {:reply, {:error, {:rate_limited, max(retry_after, 1)}}, put_in(state.hits[user_id], recent)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.window_ms

    hits =
      for {user, stamps} <- state.hits,
          recent = prune(stamps, cutoff),
          recent != [],
          into: %{},
          do: {user, recent}

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp prune(stamps, cutoff), do: Enum.take_while(stamps, &(&1 > cutoff))

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_config!(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{default, overrides}]}
      when is_integer(default) and default >= 0 and is_map(overrides) ->
        {default, overrides}

      {:ok, _} ->
        raise ArgumentError, "#{path}: expected a single {default_limit, %{user => limit}} term"

      {:error, reason} ->
        raise ArgumentError, "cannot read rate limit config #{path}: #{inspect(reason)}"
    end
  end
end

# --- Example caller (requires Phoenix; not compiled here) ---------------------
#
# defmodule MyAppWeb.ReportController do
#   use MyAppWeb, :controller
#
#   def create(conn, params) do
#     user = conn.assigns.current_user
#
#     case MyApp.RateLimiter.check(user.id) do
#       :ok ->
#         report = MyApp.Reports.generate(user, params)
#         json(conn, report)
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
# Background job (e.g. an Oban worker):
#
#   def perform(%Oban.Job{args: %{"user_id" => id}}) do
#     case MyApp.RateLimiter.check(id) do
#       :ok -> MyApp.Sync.run(id)
#       {:error, {:rate_limited, ms}} -> {:snooze, max(div(ms, 1000), 1)}
#     end
#   end
