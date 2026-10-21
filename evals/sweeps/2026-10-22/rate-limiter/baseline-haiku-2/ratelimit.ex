defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any rolling
  60-second window. N is read from a JSON config file when the limiter starts.

  ## Config file

      {
        "default": 60,
        "users": {
          "42": 300,
          "7": 10
        }
      }

  `default` applies to every user not listed under `users`. Keys in `users`
  are strings. Integer user IDs are converted with `to_string/1`, so `42` and
  `"42"` refer to the same user. Every limit must be a positive integer, or
  startup fails.

  ## Starting

  Add the limiter to the supervision tree in `MyApp.Application`:

      children = [
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Checking

  Call `check/1` before doing the work. It returns `:ok` and counts the
  request, or `{:error, :rate_limited, retry_after_ms}` and does not count it.

  Controller plug:

      defmodule MyAppWeb.RateLimitPlug do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, :rate_limited, retry_after_ms} ->
              seconds = div(retry_after_ms + 999, 1000)

              conn
              |> put_resp_header("retry-after", Integer.to_string(seconds))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  Background job (Oban-style, where `{:snooze, seconds}` reschedules the job):

      def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok ->
            do_work(args)

          {:error, :rate_limited, retry_after_ms} ->
            {:snooze, div(retry_after_ms + 999, 1000)}
        end
      end

  Both examples assume the app's own auth and job modules, so they are not
  compiled here.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter. Requires the `:config_path` option. Reads and validates
  the config file in `init/1`, so a bad file stops startup.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records one request for `user_id` if it is under the limit.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` where
  `retry_after_ms` is how long until the user's oldest counted request leaves
  the window.
  """
  @spec check(user_id()) :: :ok | {:error, :rate_limited, pos_integer()}
  def check(user_id) when is_integer(user_id) or is_binary(user_id) do
    GenServer.call(__MODULE__, {:check, to_string(user_id)})
  end

  @impl true
  def init(opts) do
    config = opts |> Keyword.fetch!(:config_path) |> load_config!()
    schedule_sweep()
    {:ok, %{config: config, windows: %{}}}
  end

  @impl true
  def handle_call({:check, key}, _from, state) do
    now = now_ms()
    limit = limit_for(state.config, key)
    timestamps = state.windows |> Map.get(key, []) |> prune(now)

    if length(timestamps) < limit do
      {:reply, :ok, put_window(state, key, [now | timestamps])}
    else
      retry_after = List.last(timestamps) + @window_ms - now
      {:reply, {:error, :rate_limited, retry_after}, put_window(state, key, timestamps)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    windows =
      state.windows
      |> Enum.map(fn {key, timestamps} -> {key, prune(timestamps, now)} end)
      |> Enum.reject(fn {_key, timestamps} -> timestamps == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | windows: windows}}
  end

  defp load_config!(path) do
    decoded = path |> File.read!() |> :json.decode()
    default = Map.fetch!(decoded, "default")
    users = Map.get(decoded, "users", %{})

    validate_limit!(default)
    Enum.each(users, fn {_user, limit} -> validate_limit!(limit) end)

    %{default: default, users: users}
  end

  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(other) do
    raise ArgumentError, "rate limit must be a positive integer, got: #{inspect(other)}"
  end

  defp limit_for(%{default: default, users: users}, key), do: Map.get(users, key, default)

  # Timestamps are stored newest first, so take_while stops at the first expired one.
  defp prune(timestamps, now) do
    Enum.take_while(timestamps, &(&1 > now - @window_ms))
  end

  defp put_window(state, key, timestamps) do
    %{state | windows: Map.put(state.windows, key, timestamps)}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
