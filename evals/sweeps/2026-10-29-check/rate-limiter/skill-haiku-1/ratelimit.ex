defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user a fixed number of requests in any rolling one-minute window.

  The limits come from a JSON file that is read once, when the process starts:

      {"default": 60, "users": {"42": 300, "817": 10}}

  `"users"` maps a user ID, written as a string, to that user's limit. A user
  who is not listed gets `"default"`. Every limit must be a positive integer.
  A file of any other shape stops the process at start, so the mistake shows
  at boot instead of on the first request.

  Every check goes through this one process. It handles its messages one at a
  time, so two concurrent requests cannot both read the same count.

  ## Starting it

  Add it to the supervision tree with the path to the limits file:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint
      ]

  ## Callers

  A controller answers 429 when the user is over the limit:

      def create(conn, params) do
        user = conn.assigns.current_user

        case MyApp.RateLimiter.check(user.id) do
          :ok ->
            report = Reports.create!(user, params)
            render(conn, :show, report: report)

          {:error, {:rate_limited, retry_after_ms}} ->
            retry_after_seconds = div(retry_after_ms, 1000) + 1

            conn
            |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
            |> send_resp(:too_many_requests, "")
        end
      end

  A background job reschedules itself instead of doing the work:

      def perform(%{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok ->
            Exports.run(user_id)

          {:error, {:rate_limited, retry_after_ms}} ->
            {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @doc """
  Starts the limiter and reads its limits file.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - name to register the process under. Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config_path), name: name)
  end

  @doc """
  Records one request by `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed. Otherwise returns
  `{:error, {:rate_limited, retry_after_ms}}`, where `retry_after_ms` is the
  time until the user's oldest counted request leaves the window.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @impl true
  def init(config_path) do
    config = read_config!(config_path)
    schedule_sweep()

    {:ok, %{default: config.default, limits: config.users, requests: %{}}}
  end

  @impl true
  def handle_call({:check, user_key}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_key, state.default)
    timestamps = in_window(Map.get(state.requests, user_key, []), now)

    if length(timestamps) < limit do
      requests = Map.put(state.requests, user_key, [now | timestamps])
      {:reply, :ok, %{state | requests: requests}}
    else
      requests = Map.put(state.requests, user_key, timestamps)
      retry_after_ms = List.last(timestamps) + @window_ms - now
      {:reply, {:error, {:rate_limited, retry_after_ms}}, %{state | requests: requests}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    requests =
      state.requests
      |> Map.new(fn {user_key, timestamps} -> {user_key, in_window(timestamps, now)} end)
      |> Map.reject(fn {_user_key, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  defp read_config!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> validate_config!()
  end

  defp validate_config!(%{"default" => default, "users" => users})
       when is_integer(default) and default > 0 and is_map(users) do
    if Enum.all?(users, fn {_user_key, limit} -> is_integer(limit) and limit > 0 end) do
      %{default: default, users: users}
    else
      raise ArgumentError, "every user limit must be a positive integer"
    end
  end

  defp validate_config!(_config) do
    raise ArgumentError, ~s(expected {"default": n, "users": {...}} with positive integer limits)
  end

  # Timestamps are kept newest first, so the oldest one is last.
  defp in_window(timestamps, now) do
    Enum.filter(timestamps, &(now - &1 < @window_ms))
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
