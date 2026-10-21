defmodule RateLimit do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most `limit` requests in any 60-second window. The
  limit for each user comes from a JSON config file that is read once, when
  the limiter starts.

  ## Config file

      {
        "default": 60,
        "limits": {
          "42": 300,
          "913": 10
        }
      }

  `"default"` is required and applies to any user not listed under `"limits"`.
  JSON object keys are strings, so user IDs are matched as strings. Integer
  IDs are converted with `to_string/1` before lookup.

  ## Starting

  Add the limiter to the supervision tree with the path to the config file:

      # lib/my_app/application.ex
      children = [
        {RateLimit, config_path: Path.join(:code.priv_dir(:my_app), "rate_limits.json")},
        # ... other children
      ]

  If the file is missing or invalid, `start_link/1` returns an error and the
  application does not start.

  ## Example: controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case RateLimit.check(user.id) do
            :ok ->
              report = Reports.generate!(user, params)
              json(conn, %{id: report.id})

            {:error, :rate_limited, retry_after_ms} ->
              seconds = div(retry_after_ms + 999, 1000)

              conn
              |> put_resp_header("retry-after", Integer.to_string(seconds))
              |> send_resp(429, "Too many requests")
          end
        end
      end

  ## Example: background job (Oban)

      defmodule MyApp.Workers.Export do
        use Oban.Worker, queue: :exports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
          case RateLimit.check(user_id) do
            :ok ->
              Exports.run(args)

            {:error, :rate_limited, retry_after_ms} ->
              {:snooze, div(retry_after_ms + 999, 1000)}
          end
        end
      end

  ## Notes

    * `check/1` records the request when it returns `:ok`. A rejected request
      is not recorded, so a caller that retries after `retry_after_ms` does not
      count against itself.
    * All checks go through one GenServer, so every check is serialized. This is
      fine for moderate request rates. Under very high load, move the
      per-user lists into an ETS table.
    * Memory use is bounded by the number of users who made a request in the
      last minute. A sweep runs every minute and drops idle users.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer()
  @type check_result :: :ok | {:error, :rate_limited, non_neg_integer()}

  # Public API

  @doc """
  Starts the limiter. Requires `:config_path`, the path to the JSON limits file.
  """
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, %{config_path: config_path}, name: __MODULE__)
  end

  @doc """
  Checks whether `user_id` may make a request now. If so, records the request.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` where
  `retry_after_ms` is the time until the user has a free slot.
  """
  @spec check(user_id()) :: check_result()
  def check(user_id) do
    GenServer.call(__MODULE__, {:check, to_string(user_id)})
  end

  # GenServer callbacks

  @impl true
  def init(%{config_path: path}) do
    config = load_config!(path)
    schedule_sweep()
    {:ok, %{config: config, requests: %{}}}
  end

  @impl true
  def handle_call({:check, user}, _from, state) do
    now = now_ms()
    limit = Map.get(state.config.limits, user, state.config.default)
    recent = prune(Map.get(state.requests, user, []), now)

    # `recent` is newest first. The user is allowed if fewer than `limit`
    # requests are in the window.
    if length(recent) < limit do
      requests = Map.put(state.requests, user, [now | recent])
      {:reply, :ok, %{state | requests: requests}}
    else
      # The request that must expire before a slot frees up is the one at
      # index `limit - 1`, counting from the newest. Its expiry time minus
      # `now` is the wait.
      blocking = Enum.at(recent, limit - 1)
      retry_after = blocking + @window_ms - now
      requests = Map.put(state.requests, user, recent)
      {:reply, {:error, :rate_limited, retry_after}, %{state | requests: requests}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    requests =
      state.requests
      |> Enum.map(fn {user, timestamps} -> {user, prune(timestamps, now)} end)
      |> Enum.reject(fn {_user, timestamps} -> timestamps == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  # Helpers

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  # Keeps only timestamps inside the window. Input is newest first, so
  # take_while stops at the first expired entry.
  defp prune(timestamps, now) do
    Enum.take_while(timestamps, &(&1 > now - @window_ms))
  end

  defp load_config!(path) do
    decoded = path |> File.read!() |> JSON.decode!()

    default = validate_limit!(Map.fetch!(decoded, "default"), "default")

    limits =
      decoded
      |> Map.get("limits", %{})
      |> Map.new(fn {user, limit} -> {user, validate_limit!(limit, user)} end)

    %{default: default, limits: limits}
  end

  defp validate_limit!(limit, _key) when is_integer(limit) and limit > 0, do: limit

  defp validate_limit!(limit, key) do
    raise ArgumentError,
          "rate limit for #{inspect(key)} must be a positive integer, got: #{inspect(limit)}"
  end
end
