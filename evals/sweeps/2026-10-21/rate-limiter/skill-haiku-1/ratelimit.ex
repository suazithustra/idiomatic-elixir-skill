defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user a fixed number of requests in any rolling one-minute window.

  The limits are read from a JSON file when the process starts. The file maps
  each user ID to that user's allowed requests per minute:

      {"user-42": 100, "user-7": 10}

  Only allowed requests are recorded. A denied request does not count, so a
  blocked user can retry as soon as one of their older requests leaves the window.

  Every check goes through this one process, so reading a user's history,
  deciding, and recording the new request happen in one step. Concurrent
  callers cannot push a user past their limit.
  """

  use GenServer

  @window_ms :timer.minutes(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the registered name. Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, config_path, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Records one request for `user_id` if the user is within their limit.

  Returns `:ok` when the request is allowed. Returns
  `{:error, {:rate_limited, retry_after_ms}}` when the user has used their limit
  for the window, where `retry_after_ms` is the time until the oldest counted
  request leaves the window. Returns `{:error, :unknown_user}` when the limits
  file has no entry for the user.

  `user_id` is converted with `to_string/1`, because the keys in the file are strings.
  Pass `server` only when a test starts its own limiter.
  """
  @spec check(GenServer.server(), term()) ::
          :ok | {:error, {:rate_limited, pos_integer()}} | {:error, :unknown_user}
  def check(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @impl true
  def init(config_path) do
    case read_limits(config_path) do
      {:ok, limits} ->
        schedule_sweep()
        {:ok, %{limits: limits, requests: %{}}}

      {:error, reason} ->
        {:stop, {:rate_limit_config, config_path, reason}}
    end
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    case Map.fetch(state.limits, user_id) do
      {:ok, limit} ->
        now = System.monotonic_time(:millisecond)
        recent = recent_requests(Map.get(state.requests, user_id, []), now)
        {reply, recent} = admit(recent, limit, now)
        {:reply, reply, %{state | requests: Map.put(state.requests, user_id, recent)}}

      :error ->
        {:reply, {:error, :unknown_user}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    requests =
      state.requests
      |> Map.new(fn {user_id, timestamps} -> {user_id, recent_requests(timestamps, now)} end)
      |> Map.reject(fn {_user_id, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  # Timestamps are kept newest first, so the first expired one ends the window.
  defp recent_requests(timestamps, now) do
    cutoff = now - @window_ms
    Enum.take_while(timestamps, &(&1 > cutoff))
  end

  defp admit(recent, limit, now) when length(recent) < limit do
    {:ok, [now | recent]}
  end

  defp admit(recent, _limit, now) do
    retry_after_ms = List.last(recent) + @window_ms - now
    {{:error, {:rate_limited, retry_after_ms}}, recent}
  end

  # Users who stop sending requests keep an entry until a sweep finds it empty.
  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  defp read_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      validate_limits(decoded)
    end
  end

  defp validate_limits(limits) when is_map(limits) do
    case Enum.find(limits, fn {_user_id, limit} -> not valid_limit?(limit) end) do
      nil -> {:ok, limits}
      {user_id, limit} -> {:error, {:invalid_limit, user_id, limit}}
    end
  end

  defp validate_limits(_other), do: {:error, :expected_object}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end

# Starting it, in MyApp.Application.start/2:
#
#     children = [
#       MyApp.Repo,
#       {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
#       MyAppWeb.Endpoint
#     ]
#
# Caller, in a Phoenix controller (not compiled here, because Phoenix is not installed):
#
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       alias MyApp.RateLimiter
#
#       def create(conn, params) do
#         case RateLimiter.check(conn.assigns.current_user.id) do
#           :ok ->
#             json(conn, %{status: "queued"})
#
#           {:error, {:rate_limited, retry_after_ms}} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
#             |> put_status(:too_many_requests)
#             |> json(%{error: "rate_limited"})
#
#           {:error, :unknown_user} ->
#             conn
#             |> put_status(:forbidden)
#             |> json(%{error: "no_rate_limit"})
#         end
#       end
#     end
