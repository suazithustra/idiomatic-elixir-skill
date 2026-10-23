defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling 60-second window.

  Per-user limits come from a JSON file that is read once, when the process
  starts. Example file:

      {
        "default": 60,
        "users": {"42": 300, "7": 10}
      }

  Keys under `"users"` are user IDs written as strings. A user who is not
  listed gets the `"default"` limit. Every limit must be a positive integer.
  A missing file or an invalid limit stops the process at startup.

  ## Starting it

  Add the limiter to the supervision tree, with the path read from application
  config at boot:

      # config/runtime.exs
      config :my_app,
        rate_limit_config_path: System.get_env("RATE_LIMIT_CONFIG", "config/rate_limits.json")

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.fetch_env!(:my_app, :rate_limit_config_path)},
        MyAppWeb.Endpoint
      ]

  ## Callers

  A controller, which answers `429 Too Many Requests` when the user is over
  the limit:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            render_created(conn, params)

          {:error, {:rate_limited, retry_after_ms}} ->
            retry_after = Integer.to_string(Integer.ceil_div(retry_after_ms, 1000))

            conn
            |> put_resp_header("retry-after", retry_after)
            |> send_resp(:too_many_requests, "")
        end
      end

  A background job, which reschedules itself (`{:snooze, seconds}` is the
  return value Oban uses for this):

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok ->
            send_digest(user_id)

          {:error, {:rate_limited, retry_after_ms}} ->
            {:snooze, Integer.ceil_div(retry_after_ms, 1000)}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path to the JSON limits file. Defaults to the
      `:rate_limit_config_path` key of the `:my_app` application environment.
    * `:name` - registered name. Defaults to `MyApp.RateLimiter`. Tests pass
      their own name so they can run their own instance.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Counts one request for `user_id` if that user is under their limit.

  Returns `:ok` when the request is allowed. Returns
  `{:error, {:rate_limited, retry_after_ms}}` when it is not, where
  `retry_after_ms` is the time until one more request fits in the window.
  A rejected request is not counted.

  A successful call uses up one request, so call this once, right before the
  work it guards. `user_id` may be an integer or a string.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :config_path, &default_config_path/0)
    schedule_sweep()
    {:ok, %{limits: load_limits!(path), requests: %{}}}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits.users, user_id, state.limits.default)
    recent = state.requests |> Map.get(user_id, []) |> recent_requests(now)

    if length(recent) < limit do
      requests = Map.put(state.requests, user_id, [now | recent])
      {:reply, :ok, %{state | requests: requests}}
    else
      retry_after = retry_after_ms(recent, limit, now)
      {:reply, {:error, {:rate_limited, retry_after}}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    requests =
      state.requests
      |> Map.new(fn {user_id, times} -> {user_id, recent_requests(times, now)} end)
      |> Map.reject(fn {_user_id, times} -> times == [] end)

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  defp default_config_path do
    Application.fetch_env!(:my_app, :rate_limit_config_path)
  end

  defp load_limits!(path) do
    %{"default" => default, "users" => users_json} =
      path
      |> File.read!()
      |> :json.decode()

    users = Map.new(users_json, fn {user_id, limit} -> {user_id, validate_limit!(limit)} end)
    %{default: validate_limit!(default), users: users}
  end

  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: limit

  defp validate_limit!(limit) do
    raise ArgumentError, "rate limits must be positive integers, got: #{inspect(limit)}"
  end

  # Keeps only the request times still inside the window.
  defp recent_requests(times, now) do
    Enum.filter(times, &(now - &1 < @window_ms))
  end

  # `recent` is newest first. One more request fits once the request at
  # position `limit - 1` has left the window, since every older one leaves
  # with it.
  defp retry_after_ms(recent, limit, now) do
    Enum.at(recent, limit - 1) + @window_ms - now
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
