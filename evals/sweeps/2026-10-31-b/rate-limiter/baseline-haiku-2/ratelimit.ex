defmodule RateLimit do
  @moduledoc """
  Per-user rate limiter. Each user may make at most `N` checks in any rolling
  60-second window. `N` is read per user from a JSON config file when the
  limiter starts.

  ## Config file

      {
        "default": 60,
        "users": {
          "42": 300,
          "917": 10
        }
      }

  `default` applies to every user not listed under `users`. JSON object keys
  are strings, so integer user IDs are matched by their string form. Each
  limit must be an integer of at least 1.

  ## Starting

  Add it to the supervision tree:

      children = [
        {RateLimit, config_path: Path.join(:code.priv_dir(:my_app), "rate_limits.json")}
      ]

  If the file is missing or invalid, the limiter fails to start and the
  supervisor reports `{:invalid_rate_limit_config, reason}`.

  ## Checking

  `check/1` counts the request only when it is allowed. Call it before doing
  the work:

      # Phoenix controller
      def create(conn, params) do
        case RateLimit.check(conn.assigns.current_user.id) do
          :ok ->
            do_create(conn, params)

          {:error, {:rate_limited, retry_after_ms}} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
            |> send_resp(429, "Too many requests")
        end
      end

      # Background job (Oban-style snooze)
      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case RateLimit.check(user_id) do
          :ok -> do_work(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end

  ## Notes

  Each check is a `GenServer.call`, so all checks pass through one process.
  That is fine for moderate traffic. If it becomes a bottleneck, move the
  per-user lists into an ETS table owned by this process.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Public API

  @doc "Starts the limiter. Requires the `:config_path` option."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `:ok` and records the request if the user is under their limit.
  Otherwise returns `{:error, {:rate_limited, retry_after_ms}}`, where
  `retry_after_ms` is how long until the user's oldest counted request leaves
  the window.
  """
  @spec check(String.t() | integer()) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(user_id) do
    GenServer.call(__MODULE__, {:check, key(user_id)})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)

    case load_config(path) do
      {:ok, config} ->
        schedule_sweep()
        {:ok, %{default: config.default, users: config.users, hits: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, reason}}
    end
  end

  @impl true
  def handle_call({:check, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.users, key, state.default)

    # Newest first, so take_while keeps only the requests still in the window.
    recent = state.hits |> Map.get(key, []) |> Enum.take_while(&(&1 > now - @window_ms))

    if length(recent) < limit do
      {:reply, :ok, %{state | hits: Map.put(state.hits, key, [now | recent])}}
    else
      oldest = List.last(recent)
      retry_after = max(oldest + @window_ms - now, 0)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: Map.put(state.hits, key, recent)}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms

    hits =
      state.hits
      |> Map.new(fn {key, times} -> {key, Enum.take_while(times, &(&1 > cutoff))} end)
      |> Map.reject(fn {_key, times} -> times == [] end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp key(user_id) when is_binary(user_id) or is_integer(user_id), do: to_string(user_id)

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp load_config(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"default" => default} = config} <- JSON.decode(contents),
         users = Map.get(config, "users", %{}),
         true <- valid_limit?(default) and is_map(users) and Enum.all?(users, fn {_id, n} -> valid_limit?(n) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_config}
    end
  end

  defp valid_limit?(n), do: is_integer(n) and n >= 1
end
