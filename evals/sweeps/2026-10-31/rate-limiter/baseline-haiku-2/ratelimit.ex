defmodule RateLimit do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any
  rolling 60-second window. N is set per user in a JSON file that is read
  once when the limiter starts.

  ## Config file

  The file is JSON (requires Elixir 1.18+ for the built-in `JSON` module):

      {
        "default": 30,
        "users": {
          "42": 120,
          "97": 5
        }
      }

  `default` applies to every user not listed under `users`. Keys under
  `users` are user IDs as strings. Every limit must be a positive integer.

  ## Starting it

      # lib/my_app/application.ex
      children = [
        {RateLimit, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        ...
      ]

  If the file is missing or invalid, startup fails with an exception.

  ## Checking it

      case RateLimit.check(user.id) do
        :ok -> do_the_work()
        {:error, :rate_limited, retry_after_ms} -> ...
      end

  Each call to `check/1` counts as one request, whether or not it is allowed.
  Calls are serialized through a single process, so this works on one node
  only. Counts are held in memory and reset when the node restarts.
  """

  use GenServer

  @window_ms 60_000
  @sweep_every_ms 60_000

  ## Client API

  @doc """
  Starts the limiter. Requires the `:config_path` option.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records one request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed. Returns
  `{:error, :rate_limited, retry_after_ms}` when it is not, where
  `retry_after_ms` is the time until the user is next under the limit.
  """
  @spec check(integer() | String.t()) :: :ok | {:error, :rate_limited, pos_integer()}
  def check(user_id) do
    GenServer.call(__MODULE__, {:check, user_id})
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    limits = RateLimit.Config.load!(path)
    schedule_sweep()
    {:ok, %{limits: limits, hits: %{}}}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    key = to_string(user_id)
    limit = Map.get(state.limits.users, key, state.limits.default)

    # Timestamps are stored newest first, so the expired ones are at the end.
    recent =
      state.hits
      |> Map.get(key, [])
      |> Enum.take_while(&(&1 > now - @window_ms))

    if length(recent) < limit do
      {:reply, :ok, put_hits(state, key, [now | recent])}
    else
      # The oldest kept timestamp is the first to leave the window.
      retry_after = List.last(recent) + @window_ms - now
      {:reply, {:error, :rate_limited, retry_after}, put_hits(state, key, recent)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - @window_ms

    hits =
      state.hits
      |> Map.new(fn {key, timestamps} -> {key, Enum.take_while(timestamps, &(&1 > cutoff))} end)
      |> Map.reject(fn {_key, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp put_hits(state, key, timestamps) do
    %{state | hits: Map.put(state.hits, key, timestamps)}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)
end

defmodule RateLimit.Config do
  @moduledoc false

  @doc """
  Reads the limits file at `path`. Raises if the file cannot be read or is
  not in the expected shape.
  """
  def load!(path) do
    path
    |> File.read!()
    |> JSON.decode!()
    |> parse!()
  end

  defp parse!(%{"default" => default} = config) when is_integer(default) and default > 0 do
    users = Map.get(config, "users", %{})

    unless is_map(users) do
      raise ArgumentError, ~s(rate limit config: "users" must be a JSON object)
    end

    users =
      Map.new(users, fn
        {id, limit} when is_integer(limit) and limit > 0 ->
          {id, limit}

        {id, other} ->
          raise ArgumentError,
                "rate limit config: limit for user #{id} must be a positive integer, got: #{inspect(other)}"
      end)

    %{default: default, users: users}
  end

  defp parse!(_other) do
    raise ArgumentError,
          ~s(rate limit config: must be a JSON object with "default" as a positive integer)
  end
end

# ---------------------------------------------------------------------------
# Example callers (not compiled here; they need Phoenix and Oban)
# ---------------------------------------------------------------------------
#
# Phoenix controller:
#
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       def create(conn, params) do
#         case RateLimit.check(conn.assigns.current_user.id) do
#           :ok ->
#             report = Reports.create!(params)
#             json(conn, %{id: report.id})
#
#           {:error, :rate_limited, retry_after_ms} ->
#             seconds = div(retry_after_ms + 999, 1000)
#
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(seconds))
#             |> put_status(:too_many_requests)
#             |> json(%{error: "rate_limited", retry_after_seconds: seconds})
#         end
#       end
#     end
#
# Background job (Oban). Returning {:snooze, seconds} reschedules the job
# instead of failing it:
#
#     defmodule MyApp.Workers.SendDigest do
#       use Oban.Worker, queue: :default
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case RateLimit.check(user_id) do
#           :ok ->
#             MyApp.Digests.send_for(user_id)
#
#           {:error, :rate_limited, retry_after_ms} ->
#             {:snooze, div(retry_after_ms + 999, 1000)}
#         end
#       end
#     end
