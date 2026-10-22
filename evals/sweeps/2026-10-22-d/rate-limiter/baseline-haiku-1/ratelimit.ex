defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any rolling
  60-second window. N is read per user from a JSON config file when the
  limiter starts.

  ## Configuration file

      {
        "default": 60,
        "users": {
          "42": 300,
          "99": 10
        }
      }

  `"default"` applies to every user not listed under `"users"`. A limit of `0`
  blocks the user entirely. User ids are matched by their string form, so `42`
  and `"42"` refer to the same user.

  ## Starting

  Add the limiter to the supervision tree and point it at the config file:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_config)},
        MyAppWeb.Endpoint
      ]

  If the file is missing or malformed, `start_link/1` raises and the supervisor
  fails to boot, so a bad config is caught at deploy time rather than on the
  first request.

  ## Callers

  A controller plug:

      defmodule MyAppWeb.Plugs.RateLimit do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              retry_after_s = div(retry_after_ms + 999, 1000)

              conn
              |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  A background job:

      def perform(%{args: %{"user_id" => user_id}} = job) do
        case MyApp.RateLimiter.check(user_id) do
          :ok ->
            do_the_work(job)

          {:error, {:rate_limited, retry_after_ms}} ->
            {:snooze, div(retry_after_ms + 999, 1000)}
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer()
  @type result :: :ok | {:error, {:rate_limited, pos_integer()}}

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the JSON config file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within the user's limit.

  Returns `:ok` when the request is allowed, or
  `{:error, {:rate_limited, retry_after_ms}}` when the user has used up their
  window. `retry_after_ms` is how long until the next request would be allowed.
  """
  @spec check(user_id(), GenServer.server()) :: result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @impl true
  def init(opts) do
    {default_limit, limits} = opts |> Keyword.fetch!(:config_path) |> load_config!()
    schedule_sweep()

    {:ok, %{default_limit: default_limit, limits: limits, requests: %{}}}
  end

  @impl true
  def handle_call({:check, user_key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits, user_key, state.default_limit)
    timestamps = state.requests |> Map.get(user_key, []) |> in_window(now) |> Enum.take(limit)

    if length(timestamps) < limit do
      {:reply, :ok, store(state, user_key, [now | timestamps])}
    else
      reply = {:error, {:rate_limited, retry_after(timestamps, now)}}
      {:reply, reply, store(state, user_key, timestamps)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    requests =
      state.requests
      |> Enum.map(fn {user_key, timestamps} -> {user_key, in_window(timestamps, now)} end)
      |> Enum.reject(fn {_user_key, timestamps} -> timestamps == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  # Timestamps are kept newest first, so the window is a prefix of the list.
  defp in_window(timestamps, now) do
    cutoff = now - @window_ms
    Enum.take_while(timestamps, &(&1 > cutoff))
  end

  # `timestamps` has been trimmed to at most `limit` entries, so when the user
  # is full the last one is the oldest request that must expire to free a slot.
  defp retry_after([], _now), do: @window_ms
  defp retry_after(timestamps, now), do: List.last(timestamps) + @window_ms - now

  defp store(state, user_key, []), do: %{state | requests: Map.delete(state.requests, user_key)}

  defp store(state, user_key, timestamps) do
    %{state | requests: Map.put(state.requests, user_key, timestamps)}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_config!(path) do
    config = path |> File.read!() |> JSON.decode!()
    default = Map.fetch!(config, "default")
    users = Map.get(config, "users", %{})

    validate_limit!(default, "default")
    Enum.each(users, fn {user_id, limit} -> validate_limit!(limit, "users.#{user_id}") end)

    {default, users}
  end

  defp validate_limit!(limit, _where) when is_integer(limit) and limit >= 0, do: :ok

  defp validate_limit!(limit, where) do
    raise ArgumentError,
          "rate limit for #{where} must be a non-negative integer, got: #{inspect(limit)}"
  end
end
