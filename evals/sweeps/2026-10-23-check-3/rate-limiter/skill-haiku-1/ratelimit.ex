defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  Limits are read once, when the process starts, from a JSON file:

      {
        "default_limit": 60,
        "users": {"42": 300, "77": 10}
      }

  `"default_limit"` applies to every user not listed under `"users"`. Every
  limit must be a positive integer. Keys under `"users"` are user ids written
  as strings, so `"42"` in the file applies to user id `42` in code.

  An allowed request is recorded. A denied request is not, so a blocked user
  gets capacity back as soon as their oldest recorded request leaves the window.

  All checks go through one process, so concurrent callers cannot both take the
  last free slot.

  ## Starting

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  ## Checking

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_the_work()
        {:error, {:rate_limited, retry_after_ms}} -> wait_or_reject(retry_after_ms)
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(5)

  @doc """
  Starts the limiter. Requires `:config_path`.

  Returns `{:error, reason}` when the file cannot be read, is not valid JSON,
  or does not have the shape described in the module docs.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config_path), name: __MODULE__)
  end

  @doc """
  Records one request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed, or `{:error, {:rate_limited,
  retry_after_ms}}` when it is not. `retry_after_ms` is how long until the
  user's oldest recorded request leaves the window, so a retry after that
  delay will succeed.
  """
  @spec check(integer() | String.t()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id) when is_integer(user_id) or is_binary(user_id) do
    GenServer.call(__MODULE__, {:check, to_string(user_id)})
  end

  @impl GenServer
  def init(config_path) do
    case load_limits(config_path) do
      {:ok, limits} ->
        schedule_sweep()
        {:ok, %{limits: limits, requests: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:check, user_key}, _from, state) do
    now = now_ms()
    recent = recent_requests(Map.get(state.requests, user_key, []), now)

    if length(recent) < limit_for(state, user_key) do
      requests = Map.put(state.requests, user_key, [now | recent])
      {:reply, :ok, %{state | requests: requests}}
    else
      retry_after_ms = List.last(recent) + @window_ms - now
      {:reply, {:error, {:rate_limited, retry_after_ms}}, state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    # Drops timestamps that have left the window and removes users with none
    # left, so the map does not grow with every user who ever made a request.
    now = now_ms()

    requests =
      state.requests
      |> Enum.map(fn {user_key, times} -> {user_key, recent_requests(times, now)} end)
      |> Enum.reject(fn {_user_key, recent} -> recent == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_limits(decoded)
    end
  end

  defp parse_limits(%{"default_limit" => default_limit, "users" => users})
       when is_map(users) do
    if valid_limit?(default_limit) and Enum.all?(Map.values(users), &valid_limit?/1) do
      {:ok, %{default: default_limit, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_config}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0

  defp limit_for(state, user_key) do
    Map.get(state.limits.users, user_key, state.limits.default)
  end

  # Requests are stored newest first, so the first expired one ends the window.
  defp recent_requests(times, now) do
    Enum.take_while(times, &(now - &1 < @window_ms))
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  # Monotonic time is not affected by wall-clock changes such as NTP adjustments.
  defp now_ms, do: System.monotonic_time(:millisecond)
end

# Caller in a Phoenix controller (needs Phoenix, so not compiled here):
#
#   defmodule MyAppWeb.ExportController do
#     use MyAppWeb, :controller
#
#     def create(conn, _params) do
#       case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
#         :ok ->
#           start_export(conn)
#
#         {:error, {:rate_limited, retry_after_ms}} ->
#           seconds = div(retry_after_ms + 999, 1000)
#
#           conn
#           |> put_resp_header("retry-after", Integer.to_string(seconds))
#           |> send_resp(429, "Too many requests")
#       end
#     end
#   end
#
# Caller in a background job (Oban-style, needs Oban, so not compiled here):
#
#   def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) do
#     case MyApp.RateLimiter.check(user_id) do
#       :ok -> do_the_work(job)
#       {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms + 999, 1000)}
#     end
#   end
