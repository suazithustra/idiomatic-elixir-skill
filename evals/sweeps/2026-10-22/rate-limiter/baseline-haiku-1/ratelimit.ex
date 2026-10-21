defmodule RateLimiter do
  @moduledoc """
  Per-user rate limiter. Each user may make at most `N` requests in any
  rolling 60-second window. `N` comes from a JSON configuration file that is
  read once, when the limiter starts.

  ## Configuration file

      {
        "default": 60,
        "users": {
          "42": 300,
          "97": 10
        }
      }

  `default` applies to every user not listed under `users`. Keys under
  `users` are user IDs written as strings. Every limit must be a positive
  integer. To change a limit, edit the file and restart the limiter.

  ## Starting it

  Add it to the supervision tree, for example in `MyApp.Application`:

      children = [
        {RateLimiter, config_path: "config/rate_limits.json"}
      ]

  If `:config_path` is not passed, the path is read from
  `Application.get_env(:rate_limiter, :config_path)`. If neither is set,
  or the file is missing or invalid, the limiter fails to start.

  ## Checking a request

      case RateLimiter.check(user.id) do
        :ok ->
          do_the_work()

        {:error, :rate_limited, retry_after_ms} ->
          {:error, retry_after_ms}
      end

  The check and the recording happen in one call, so a granted request
  counts immediately, even if the work it guards later fails. Rejected
  requests are not recorded, so a blocked user is not penalised further
  while still blocked.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer()
  @type check_result :: :ok | {:error, :rate_limited, non_neg_integer()}

  # Public API

  @doc """
  Starts the limiter. Options:

    * `:config_path` - path to the JSON configuration file.
    * `:name` - registered name. Defaults to `#{inspect(__MODULE__)}`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed, or
  `{:error, :rate_limited, retry_after_ms}` when it is not. `retry_after_ms`
  is the number of milliseconds until the user's next request would be
  allowed.
  """
  @spec check(user_id(), GenServer.server()) :: check_result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :config_path, fn -> Application.get_env(:rate_limiter, :config_path) end)

    case load_config(path) do
      {:ok, limits} ->
        schedule_sweep()
        {:ok, %{limits: limits, requests: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms
    key = to_string(user_id)
    limit = Map.get(state.limits.users, key, state.limits.default)

    # Timestamps are stored newest first, so the expired ones sit at the end.
    recent = state.requests |> Map.get(key, []) |> Enum.take_while(&(&1 > cutoff))

    if length(recent) < limit do
      requests = Map.put(state.requests, key, [now | recent])
      {:reply, :ok, %{state | requests: requests}}
    else
      # One slot frees up when the request at position `limit` expires.
      next_slot_at = Enum.at(recent, limit - 1) + @window_ms
      requests = Map.put(state.requests, key, recent)
      {:reply, {:error, :rate_limited, next_slot_at - now}, %{state | requests: requests}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    # Drop expired timestamps and forget users with none left, so memory
    # does not grow with every user who has ever made a request.
    cutoff = System.monotonic_time(:millisecond) - @window_ms

    requests =
      for {key, times} <- state.requests,
          live = Enum.take_while(times, &(&1 > cutoff)),
          live != [],
          into: %{},
          do: {key, live}

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  # Configuration

  defp load_config(nil), do: {:error, :missing_config_path}

  defp load_config(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_limits(decoded)
    else
      {:error, reason} -> {:error, {:invalid_config, path, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = config) when is_integer(default) and default > 0 do
    case Map.get(config, "users", %{}) do
      users when is_map(users) -> parse_user_limits(users, default)
      other -> {:error, {:invalid_users, other}}
    end
  end

  defp parse_limits(other), do: {:error, {:invalid_config, other}}

  defp parse_user_limits(users, default) do
    Enum.reduce_while(users, {:ok, %{default: default, users: %{}}}, fn
      {id, limit}, {:ok, acc} when is_binary(id) and is_integer(limit) and limit > 0 ->
        {:cont, {:ok, put_in(acc, [:users, id], limit)}}

      {id, limit}, _acc ->
        {:halt, {:error, {:invalid_limit, id, limit}}}
    end)
  end

  # Housekeeping

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end

# ---------------------------------------------------------------------------
# Callers (not compiled here, because they need Phoenix and Oban)
#
# Phoenix controller plug. Halts with HTTP 429 when the user is over limit.
#
#     defmodule MyAppWeb.RateLimitPlug do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(conn, _opts) do
#         case RateLimiter.check(conn.assigns.current_user.id) do
#           :ok ->
#             conn
#
#           {:error, :rate_limited, retry_after_ms} ->
#             retry_after_s = max(div(retry_after_ms, 1000), 1)
#
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
#             |> send_resp(429, "Too many requests")
#             |> halt()
#         end
#       end
#     end
#
# A controller action that checks the limit itself:
#
#     def export(conn, _params) do
#       case RateLimiter.check(conn.assigns.current_user.id) do
#         :ok ->
#           json(conn, Reports.export(conn.assigns.current_user))
#
#         {:error, :rate_limited, retry_after_ms} ->
#           conn
#           |> put_status(:too_many_requests)
#           |> json(%{error: "rate_limited", retry_after_ms: retry_after_ms})
#       end
#     end
#
# Background job (Oban worker). Snoozes the job until the user has a free slot.
#
#     defmodule MyApp.Workers.SendDigest do
#       use Oban.Worker, queue: :digests
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case RateLimiter.check(user_id) do
#           :ok ->
#             MyApp.Digests.send_for(user_id)
#
#           {:error, :rate_limited, retry_after_ms} ->
#             {:snooze, max(div(retry_after_ms, 1000), 1)}
#         end
#       end
#     end
