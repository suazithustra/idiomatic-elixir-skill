defmodule RateLimit do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any rolling
  60-second window. N is read per user from a JSON configuration file when the
  limiter starts.

  ## Configuration file

      {
        "default": 60,
        "users": {
          "42": 300,
          "97": 10
        }
      }

    * `default` is the limit for any user not listed under `users`.
    * Keys under `users` are user IDs as strings.
    * Every limit must be an integer of at least 1.

  The file is read in `init/1`. A missing, malformed, or invalid file stops
  the limiter with an error at startup rather than running with wrong limits.

  Requires OTP 27 or later (for the built-in `:json` module).

  ## Starting

  Add the limiter to the application supervision tree:

      children = [
        {RateLimit, config_path: Path.join(:code.priv_dir(:my_app), "rate_limits.json")}
      ]

  ## Checking a request

      case RateLimit.hit(user.id) do
        :ok ->
          do_the_work()

        {:error, :rate_limited, retry_after_ms} ->
          {:error, retry_after_ms}
      end

  `hit/1` records the request when it is allowed. A rejected request is not
  recorded, so a blocked user regains access as soon as their oldest recorded
  request leaves the window.

  ## Example: Phoenix controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case RateLimit.hit(user.id) do
            :ok ->
              report = Reports.generate!(user, params)
              json(conn, %{id: report.id})

            {:error, :rate_limited, retry_after_ms} ->
              conn
              |> put_resp_header("retry-after", to_string(div(retry_after_ms + 999, 1000)))
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  ## Example: Oban worker

      defmodule MyApp.Workers.SendDigest do
        use Oban.Worker, queue: :default

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case RateLimit.hit(user_id) do
            :ok ->
              Digests.send_for(user_id)

            {:error, :rate_limited, retry_after_ms} ->
              {:snooze, div(retry_after_ms + 999, 1000)}
          end
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @cleanup_interval_ms 60_000

  @type config :: %{default: pos_integer(), users: %{String.t() => pos_integer()}}

  @doc """
  Starts the limiter. Requires the `:config_path` option.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config_path), name: __MODULE__)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  `user_id` may be an integer or a string. Returns `:ok` when the request is
  allowed, or `{:error, :rate_limited, retry_after_ms}` when it is not, where
  `retry_after_ms` is the time until the user's next request is allowed.
  """
  @spec hit(integer() | String.t()) :: :ok | {:error, :rate_limited, pos_integer()}
  def hit(user_id) do
    GenServer.call(__MODULE__, {:hit, to_string(user_id)})
  end

  @doc """
  Reads and validates a configuration file. Returns `{:ok, config}` or
  `{:error, reason}`.
  """
  @spec load_config(Path.t()) :: {:ok, config()} | {:error, term()}
  def load_config(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, data} <- decode(contents) do
      parse(data)
    end
  end

  @impl true
  def init(path) do
    case load_config(path) do
      {:ok, config} ->
        schedule_cleanup()
        {:ok, %{config: config, windows: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, path, reason}}
    end
  end

  @impl true
  def handle_call({:hit, key}, _from, state) do
    now = now_ms()
    limit = limit_for(state.config, key)
    recent = state.windows |> Map.get(key, []) |> prune(now)

    if length(recent) < limit do
      windows = Map.put(state.windows, key, [now | recent])
      {:reply, :ok, %{state | windows: windows}}
    else
      # Limits are at least 1, so `recent` is never empty here. The oldest
      # entry is the last one because the list is newest first.
      retry_after = List.last(recent) + @window_ms - now
      windows = Map.put(state.windows, key, recent)
      {:reply, {:error, :rate_limited, retry_after}, %{state | windows: windows}}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = now_ms()

    windows =
      state.windows
      |> Enum.map(fn {key, recent} -> {key, prune(recent, now)} end)
      |> Enum.reject(fn {_key, recent} -> recent == [] end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | windows: windows}}
  end

  defp decode(contents) do
    {:ok, :json.decode(contents)}
  rescue
    _ -> {:error, :invalid_json}
  end

  defp parse(%{"default" => default, "users" => users}) when is_map(users) do
    if valid_limit?(default) and Enum.all?(users, fn {_id, limit} -> valid_limit?(limit) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse(_data), do: {:error, :invalid_format}

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 1

  defp limit_for(%{users: users, default: default}, key) do
    Map.get(users, key, default)
  end

  # Keeps only timestamps inside the window. The list is newest first, so
  # the scan stops at the first expired entry.
  defp prune(recent, now) do
    Enum.take_while(recent, &(&1 > now - @window_ms))
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
