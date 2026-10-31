defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most `N` requests in any 60-second window. `N` comes
  from a JSON config file that is read once, when the limiter starts:

      {
        "default": 60,
        "users": {"42": 300, "7": 5}
      }

  Users not listed under `"users"` get the `"default"` limit. Both values must
  be positive integers. A missing or invalid file stops the process at startup.

  Every `check/2` that returns `:ok` counts as one request. Callers should call
  it once per unit of work they want to count.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer()
  @type check_result :: :ok | {:error, :rate_limited, retry_after_ms :: pos_integer()}

  ## Public API

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` - required. Path to the JSON config file.
    * `:name` - optional. Registered name. Defaults to `#{inspect(__MODULE__)}`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records one request for `user_id` if the user is under their limit.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` when the user has
  used all of their requests in the last minute. `retry_after_ms` is the time
  until the oldest counted request leaves the window.
  """
  @spec check(user_id(), GenServer.server()) :: check_result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    {default, limits} = load_config!(path)
    schedule_sweep()

    {:ok, %{default: default, limits: limits, windows: %{}}}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    key = key(user_id)
    now = now_ms()
    limit = Map.get(state.limits, key, state.default)

    # Timestamps are stored newest first, so take_while stops at the first expired one.
    recent = state.windows |> Map.get(key, []) |> Enum.take_while(&(&1 > now - @window_ms))

    if length(recent) < limit do
      windows = Map.put(state.windows, key, [now | recent])
      {:reply, :ok, %{state | windows: windows}}
    else
      retry_after = List.last(recent) + @window_ms - now
      windows = Map.put(state.windows, key, recent)
      {:reply, {:error, :rate_limited, retry_after}, %{state | windows: windows}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - @window_ms

    # Drop expired timestamps and forget users with none left, so memory does not grow
    # with every user who has ever made a request.
    windows =
      state.windows
      |> Enum.map(fn {key, times} -> {key, Enum.take_while(times, &(&1 > cutoff))} end)
      |> Enum.reject(fn {_key, times} -> times == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | windows: windows}}
  end

  ## Helpers

  defp load_config!(path) do
    decoded = path |> File.read!() |> JSON.decode!()

    default = positive_int!(Map.fetch!(decoded, "default"), "default")

    limits =
      decoded
      |> Map.get("users", %{})
      |> Map.new(fn {id, n} -> {id, positive_int!(n, "users.#{id}")} end)

    {default, limits}
  end

  defp positive_int!(n, _label) when is_integer(n) and n > 0, do: n

  defp positive_int!(_value, label) do
    raise ArgumentError, "rate limit #{label} must be a positive integer"
  end

  # The config file keys are strings, so integer IDs are converted to match.
  defp key(id) when is_integer(id), do: Integer.to_string(id)
  defp key(id) when is_binary(id), do: id

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end

# ---------------------------------------------------------------------------
# Usage (not compiled; Phoenix is not part of this file)
#
# 1. Config file, e.g. config/rate_limits.json:
#
#      {"default": 60, "users": {"42": 300}}
#
# 2. Start it in the supervision tree (lib/my_app/application.ex):
#
#      config_path = Application.fetch_env!(:my_app, :rate_limit_config_path)
#
#      children = [
#        {MyApp.RateLimiter, config_path: config_path},
#        # ... rest of the children
#      ]
#
#      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
#
# 3. Controller caller (Phoenix):
#
#      defmodule MyAppWeb.ReportController do
#        use MyAppWeb, :controller
#
#        alias MyApp.RateLimiter
#
#        def create(conn, params) do
#          case RateLimiter.check(conn.assigns.current_user.id) do
#            :ok ->
#              json(conn, %{report: build_report(params)})
#
#            {:error, :rate_limited, retry_after_ms} ->
#              seconds = div(retry_after_ms + 999, 1000)
#
#              conn
#              |> put_resp_header("retry-after", Integer.to_string(seconds))
#              |> put_status(:too_many_requests)
#              |> json(%{error: "rate_limited"})
#          end
#        end
#      end
#
# 4. Background job caller (plain module; works the same under Oban or Task):
#
#      defmodule MyApp.Jobs.ExportUser do
#        alias MyApp.RateLimiter
#
#        def perform(user_id) do
#          case RateLimiter.check(user_id) do
#            :ok -> do_export(user_id)
#            {:error, :rate_limited, retry_after_ms} -> {:snooze, div(retry_after_ms, 1000) + 1}
#          end
#        end
#      end
#
#    The {:snooze, seconds} return is Oban's; for other runners, reschedule
#    after `retry_after_ms` instead.
# ---------------------------------------------------------------------------
