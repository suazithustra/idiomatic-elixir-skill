defmodule RateLimiter do
  @moduledoc """
  Per-user rate limiter with a rolling one-minute window.

  Each user may make at most N requests in any 60-second span, where N comes
  from a JSON configuration file that is read once when the limiter starts.

  ## Configuration file

      {
        "default_limit": 30,
        "users": {
          "42": 120,
          "policy-bot": 1000
        }
      }

  - `default_limit` applies to every user not listed under `users`.
  - Keys under `users` are user IDs. Integer IDs are matched by their string form.
  - Every limit must be a positive integer. Any other value stops the limiter at start.
  - Changes to the file take effect only after the limiter restarts.

  ## Starting the limiter

  Add it to your supervision tree:

      # lib/my_app/application.ex
      children = [
        {RateLimiter, config_path: "config/rate_limits.json"}
        # ...
      ]

  If `:config_path` is omitted, the value of
  `Application.get_env(:rate_limiter, :config_path)` is used, falling back to
  `"config/rate_limits.json"`.

  ## Checking the limit from a caller

  `check/1` returns `:ok` when the request may proceed and records it. It returns
  `{:error, {:rate_limited, retry_after_ms}}` when the user is at their limit.
  A rejected check is not recorded.

  Controller:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case RateLimiter.check(user.id) do
            :ok ->
              report = Reports.generate!(user, params)
              json(conn, %{id: report.id})

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000) + 1))
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limited"})
          end
        end
      end

  Background job (Oban):

      defmodule MyApp.Workers.SyncWorker do
        use Oban.Worker, queue: :sync

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case RateLimiter.check(user_id) do
            :ok ->
              MyApp.Sync.run(user_id)

            {:error, {:rate_limited, retry_after_ms}} ->
              # Retry the job once the window has room again.
              {:snooze, div(retry_after_ms, 1000) + 1}
          end
        end
      end

  ## Notes

  - State is held in one process, so every check is serialized through it.
    This is simple and correct for a single node. It is not shared between nodes.
  - Limits are enforced per node. A user spread across several nodes can exceed
    N in total.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000
  @default_config_path "config/rate_limits.json"

  @type user_id :: integer() | String.t()
  @type result :: :ok | {:error, {:rate_limited, pos_integer()}}

  # Public API

  @doc """
  Starts the limiter and reads the configuration file.

  Options:

    * `:config_path` - path to the JSON configuration file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records one request for `user_id` if the user is under their limit.

  Returns `:ok`, or `{:error, {:rate_limited, retry_after_ms}}` where
  `retry_after_ms` is the time until the user's oldest counted request leaves
  the window.
  """
  @spec check(user_id(), GenServer.server()) :: result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :config_path) || Application.get_env(:rate_limiter, :config_path, @default_config_path)

    case load_config(path) do
      {:ok, config} ->
        schedule_sweep()

        {:ok,
         %{
           default_limit: config.default_limit,
           limits: config.limits,
           # user key => request timestamps in ms, newest first
           windows: %{}
         }}

      {:error, reason} ->
        {:stop, {:invalid_config, path, reason}}
    end
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    key = to_string(user_id)
    limit = Map.get(state.limits, key, state.default_limit)
    recent = state.windows |> Map.get(key, []) |> in_window(now)

    if length(recent) < limit do
      windows = Map.put(state.windows, key, [now | recent])
      {:reply, :ok, %{state | windows: windows}}
    else
      # The request can proceed once the oldest counted request leaves the window.
      oldest = List.last(recent)
      retry_after_ms = oldest + @window_ms - now
      windows = Map.put(state.windows, key, recent)
      {:reply, {:error, {:rate_limited, retry_after_ms}}, %{state | windows: windows}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()

    # Drop users with no requests left in the window so memory does not grow
    # with every user ever seen.
    windows =
      Enum.reduce(state.windows, %{}, fn {key, times}, acc ->
        case in_window(times, now) do
          [] -> acc
          recent -> Map.put(acc, key, recent)
        end
      end)

    schedule_sweep()
    {:noreply, %{state | windows: windows}}
  end

  # Helpers

  defp in_window(times, now) do
    Enum.filter(times, &(&1 > now - @window_ms))
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp load_config(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{} = decoded} <- JSON.decode(binary),
         {:ok, default_limit} <- validate_limit(decoded["default_limit"]),
         {:ok, limits} <- parse_users(Map.get(decoded, "users", %{})) do
      {:ok, %{default_limit: default_limit, limits: limits}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_users(users) when is_map(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {user_id, limit}, {:ok, acc} ->
      case validate_limit(limit) do
        {:ok, limit} -> {:cont, {:ok, Map.put(acc, to_string(user_id), limit)}}
        {:error, _} -> {:halt, {:error, {:invalid_limit, user_id}}}
      end
    end)
  end

  defp parse_users(_), do: {:error, :invalid_users}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp validate_limit(other), do: {:error, {:invalid_limit, other}}
end
