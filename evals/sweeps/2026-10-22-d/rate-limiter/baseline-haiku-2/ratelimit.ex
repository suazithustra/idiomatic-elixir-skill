defmodule RateLimit do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most `N` checks in any rolling 60-second window. `N`
  comes from a JSON file read once, when the server starts:

      {
        "default": 60,
        "users": {
          "42": 300,
          "97": 10
        }
      }

  Users without an entry under `"users"` get `"default"`. User IDs may be
  integers or strings; they are compared as strings.

  ## Starting it

  Add it to the supervision tree before anything that calls `check/1`:

      children = [
        MyApp.Repo,
        {RateLimit, path: "config/rate_limits.json"},
        MyAppWeb.Endpoint
      ]

  If the file is missing or malformed, startup fails with an error.

  ## Calling it

  Check before doing the work. A successful check consumes one slot.

  In a controller:

      def create(conn, params) do
        case RateLimit.check(conn.assigns.current_user.id) do
          :ok ->
            # ...do the work...

          {:error, :rate_limited, retry_after_ms} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
            |> send_resp(429, "Too many requests")
        end
      end

  In a background job (here, Oban, which can snooze a job for a number of seconds):

      def perform(%{args: %{"user_id" => user_id}} = job) do
        case RateLimit.check(user_id) do
          :ok -> do_the_work(job)
          {:error, :rate_limited, retry_after_ms} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type result :: :ok | {:error, :rate_limited, pos_integer()}

  @doc "Starts the limiter. Option `:path` is the JSON config file to read."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` where
  `retry_after_ms` is the time until the user's oldest request leaves the window.
  """
  @spec check(term()) :: result()
  def check(user_id) do
    GenServer.call(__MODULE__, {:check, user_id})
  end

  @impl GenServer
  def init(opts) do
    with {:ok, config} <- opts |> Keyword.fetch!(:path) |> load_config() do
      schedule_sweep()
      {:ok, %{config: config, hits: %{}}}
    end
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    key = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.config.users, key, state.config.default)
    hits = state.hits |> Map.get(key, []) |> prune(now)

    if length(hits) < limit do
      {:reply, :ok, %{state | hits: Map.put(state.hits, key, [now | hits])}}
    else
      {:reply, {:error, :rate_limited, retry_after_ms(hits, now)},
       %{state | hits: Map.put(state.hits, key, hits)}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    # Drop expired timestamps and forget users with none left, so idle users
    # don't accumulate in memory.
    hits =
      state.hits
      |> Map.new(fn {key, timestamps} -> {key, prune(timestamps, now)} end)
      |> Map.reject(fn {_key, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  # Timestamps are kept newest first, so pruning stops at the first expired one.
  defp prune(timestamps, now) do
    cutoff = now - @window_ms
    Enum.take_while(timestamps, &(&1 > cutoff))
  end

  defp retry_after_ms([], _now), do: @window_ms
  defp retry_after_ms(timestamps, now), do: List.last(timestamps) + @window_ms - now

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp load_config(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_config(decoded)
    end
  end

  defp parse_config(%{"default" => default} = decoded) do
    users = Map.get(decoded, "users", %{})

    if valid_limit?(default) and is_map(users) and
         Enum.all?(users, fn {_id, limit} -> valid_limit?(limit) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse_config(_decoded), do: {:error, :missing_default}

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end
