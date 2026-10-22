defmodule RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most `N` requests in any rolling window (one minute by
  default), where `N` is read per user from a JSON configuration file when the
  limiter starts.

  ## Configuration file

      {
        "default": 60,
        "users": {
          "42": 300,
          "7": 10
        }
      }

  `"default"` applies to any user not listed under `"users"`. Keys under
  `"users"` are user IDs as strings; values must be positive integers.

  ## Starting it

  Add it to your supervision tree, typically in `MyApp.Application`:

      children = [
        {RateLimiter,
         config_path: Path.join(:code.priv_dir(:my_app), "rate_limits.json")}
      ]

  Options:

    * `:config_path` - required, path to the JSON file described above
    * `:window_ms` - rolling window length in milliseconds, default `60_000`
    * `:name` - registered name, default `RateLimiter`

  ## Checking the limit

  Call `check/1` before doing the work. Rejected requests are not recorded,
  so a client that backs off is not penalised further.

      case RateLimiter.check(current_user.id) do
        :ok ->
          do_work()

        {:error, {:rate_limited, retry_after_ms}} ->
          # e.g. controller: 429 with a Retry-After header
          # background job: reschedule after retry_after_ms
      end

  ### Controller example

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
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ### Background job example

      defmodule MyApp.Jobs.SyncContacts do
        def perform(%{user_id: user_id} = args) do
          case RateLimiter.check(user_id) do
            :ok ->
              ContactSync.run(user_id, args)

            {:error, {:rate_limited, retry_after_ms}} ->
              {:snooze, div(retry_after_ms, 1000) + 1}
          end
        end
      end
  """

  use GenServer

  @default_window_ms 60_000

  @type user_id :: term()
  @type check_result :: :ok | {:error, {:rate_limited, non_neg_integer()}}

  @doc """
  Starts the limiter. Reads and validates the configuration file synchronously,
  so a bad file prevents startup instead of failing on the first request.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks whether `user_id` may make another request right now.

  Returns `:ok` and records the request, or `{:error, {:rate_limited,
  retry_after_ms}}` when the user has reached their limit.
  """
  @spec check(user_id(), GenServer.server()) :: check_result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  @impl true
  def init(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    case load_config(config_path) do
      {:ok, {default, user_limits}} ->
        state = %{
          default: default,
          user_limits: user_limits,
          window_ms: window_ms,
          # user_id => request timestamps (monotonic ms), newest first,
          # truncated to the user's limit. Only the newest N can matter.
          hits: %{}
        }

        schedule_sweep(window_ms)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:config, config_path, reason}}
    end
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    # Config keys are strings, so `42` and `"42"` are the same user here.
    limit = Map.get(state.user_limits, to_string(user_id), state.default)
    window_start = now - state.window_ms

    # Newest first, so the in-window entries are a prefix of the list.
    recent = Enum.take_while(Map.get(state.hits, user_id, []), &(&1 > window_start))

    if length(recent) < limit do
      hits = Map.put(state.hits, user_id, [now | Enum.take(recent, limit - 1)])
      {:reply, :ok, %{state | hits: hits}}
    else
      # The N-th most recent request leaving the window frees a slot.
      oldest_blocking = Enum.at(recent, limit - 1)
      retry_after_ms = oldest_blocking + state.window_ms - now

      {:reply, {:error, {:rate_limited, retry_after_ms}}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    window_start = System.monotonic_time(:millisecond) - state.window_ms

    hits =
      for {user_id, [newest | _] = timestamps} <- state.hits,
          newest > window_start,
          into: %{},
          do: {user_id, timestamps}

    schedule_sweep(state.window_ms)
    {:noreply, %{state | hits: hits}}
  end

  defp schedule_sweep(window_ms) do
    Process.send_after(self(), :sweep, window_ms)
  end

  defp load_config(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{"default" => default, "users" => users}} <- decode(binary),
         :ok <- validate_limit(default),
         {:ok, user_limits} <- validate_users(users) do
      {:ok, {default, user_limits}}
    else
      {:ok, other} -> {:error, {:invalid_shape, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(binary) do
    {:ok, :json.decode(binary)}
  rescue
    error -> {:error, error}
  end

  defp validate_users(users) when is_map(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {user_id, limit}, {:ok, acc} ->
      case validate_limit(limit) do
        :ok -> {:cont, {:ok, Map.put(acc, user_id, limit)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_users(other), do: {:error, {:invalid_users, other}}

  defp validate_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp validate_limit(limit), do: {:error, {:invalid_limit, limit}}
end
