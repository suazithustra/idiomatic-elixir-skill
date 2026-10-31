defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to at most N requests in any rolling 60-second period.

  Call `check/1` before doing work. It counts the request and returns `:ok`, or
  `{:error, {:rate_limited, retry_after_seconds}}` if the user is at their limit.
  Checking and counting are one atomic step, so concurrent callers cannot slip
  past the limit together. Refused requests are not counted, so a client that
  keeps retrying gets back in as its older requests age out.

  ## Limits file

  Limits are read once, from a JSON file, when the limiter starts:

      {"default": 60, "users": {"42": 600, "c0a8e1d2-77f1-4e0b-9a55-2f1b6c3d9e10": 10}}

  `default` covers users who are not listed, such as accounts created after the
  file was written. A limit of `0` blocks a user. A missing or invalid file
  raises, which stops the application from booting instead of running without
  limits. Edits to the file apply at the next start.

  User ids may be integers or strings: `42` and `"42"` are the same user.

  ## How it works

  Each check is a call to one of several `MyApp.RateLimiter.Partition` processes,
  chosen by hashing the user id. All checks for a user go to the same process,
  which makes them atomic, and users on different partitions do not wait on each
  other. There is one partition per scheduler (the threads that run Elixir
  processes). Limits are kept in `:persistent_term`, so callers read them without
  copying.

  ## Known limits

    * Counts are held in memory on each node. On a cluster of K nodes a user can
      make up to K × N requests per minute. Enforcing one limit across nodes
      needs a shared store such as Redis.
    * If a partition crashes or the node restarts, the counts it held are lost
      and those users start with a clean window.
    * If a partition is down or does not reply within 5 seconds, `check/1` exits.
      A controller then returns a 500 and a job is retried, so no work runs
      unchecked.
  """

  use Supervisor

  @partitions MyApp.RateLimiter.Partitions
  @limits_key {__MODULE__, :limits}

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter. `:path` is the location of the limits file.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Counts a request for `user_id` if the user is under their limit.

  Returns `:ok` if the work may go ahead. Otherwise nothing is counted and the
  error holds the number of whole seconds until a retry can succeed.
  """
  @spec check(user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id) when is_integer(user_id) or is_binary(user_id) do
    key = to_string(user_id)

    GenServer.call(
      {:via, PartitionSupervisor, {@partitions, key}},
      {:check, key, limit_for(key)}
    )
  end

  defp limit_for(key) do
    {default, users} = :persistent_term.get(@limits_key)
    Map.get(users, key, default)
  end

  @impl Supervisor
  def init(opts) do
    limits = opts |> Keyword.fetch!(:path) |> load_limits!()
    :persistent_term.put(@limits_key, limits)

    children = [
      {PartitionSupervisor, child_spec: MyApp.RateLimiter.Partition, name: @partitions}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp load_limits!(path) do
    with %{"default" => default, "users" => %{} = users} <-
           path |> File.read!() |> JSON.decode!(),
         true <- Enum.all?([default | Map.values(users)], &valid_limit?/1) do
      {default, users}
    else
      _invalid ->
        raise ArgumentError,
              "invalid rate limits file #{path}: expected " <>
                ~s({"default": N, "users": {"<user id>": N}}) <>
                " where each N is a non-negative integer"
    end
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end

defmodule MyApp.RateLimiter.Partition do
  @moduledoc """
  Holds the recent request times of the users hashed to this partition.

  State is a map of user key to `{count, times}`, where `times` is a queue of
  allowed request times, oldest first. The count is stored because `:queue.len/1`
  walks the whole queue, and a check should not take longer for users with high
  limits.
  """

  use GenServer

  @window_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

  @impl GenServer
  def init(:ok) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:check, key, limit}, _from, logs) do
    # Monotonic time, so a wall clock adjustment cannot extend or cut a window.
    now = System.monotonic_time(:millisecond)
    {count, times} = logs |> Map.get(key, {0, :queue.new()}) |> expire(now - @window_ms)

    if count < limit do
      {:reply, :ok, Map.put(logs, key, {count + 1, :queue.in(now, times)})}
    else
      reply = {:error, {:rate_limited, retry_after(times, now)}}
      {:reply, reply, Map.put(logs, key, {count, times})}
    end
  end

  # Checks only expire the user making them, so users who go quiet are dropped
  # here. Without this the map would grow with every user ever seen.
  @impl GenServer
  def handle_info(:sweep, logs) do
    schedule_sweep()
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    {:noreply, Map.filter(logs, fn {_key, {_count, times}} -> active?(times, cutoff) end)}
  end

  defp expire({count, times} = log, cutoff) do
    case :queue.peek(times) do
      {:value, time} when time <= cutoff -> expire({count - 1, :queue.drop(times)}, cutoff)
      _not_expired -> log
    end
  end

  # The next slot frees up when the oldest request leaves the window. The queue
  # is only empty for a limit of 0, where no slot ever frees up.
  defp retry_after(times, now) do
    case :queue.peek(times) do
      {:value, oldest} -> ceil((oldest + @window_ms - now) / 1000)
      :empty -> div(@window_ms, 1000)
    end
  end

  defp active?(times, cutoff) do
    match?({:value, newest} when newest > cutoff, :queue.peek_r(times))
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)
end

# ---------------------------------------------------------------------------
# Starting it. These examples need Phoenix and Oban, so they are comments.
#
# List the limiter before the endpoint and any job queue, so that nothing can
# call check/1 before it is running.
#
#     # lib/my_app/application.ex
#     def start(_type, _args) do
#       children = [
#         MyApp.Repo,
#         {MyApp.RateLimiter, path: Application.app_dir(:my_app, "priv/rate_limits.json")},
#         {Oban, Application.fetch_env!(:my_app, Oban)},
#         MyAppWeb.Endpoint
#       ]
#
#       Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
#     end
#
# ---------------------------------------------------------------------------
# Calling it from controllers. A plug keeps the 429 response in one place.
#
#     # lib/my_app_web/plugs/rate_limit.ex
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(conn, _opts) do
#         case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
#           :ok ->
#             conn
#
#           {:error, {:rate_limited, retry_after}} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(retry_after))
#             |> send_resp(:too_many_requests, "Rate limit exceeded")
#             |> halt()
#         end
#       end
#     end
#
#     # lib/my_app_web/controllers/report_controller.ex
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       plug MyAppWeb.Plugs.RateLimit when action in [:create]
#
#       def create(conn, params) do
#         {:ok, report} = MyApp.Reports.create(conn.assigns.current_user, params)
#         json(conn, %{id: report.id})
#       end
#     end
#
# ---------------------------------------------------------------------------
# Calling it from a background job. The job waits and tries again when refused.
#
#     # lib/my_app/workers/export_worker.ex
#     defmodule MyApp.Workers.ExportWorker do
#       use Oban.Worker, queue: :exports
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok -> MyApp.Exports.run(user_id)
#           {:error, {:rate_limited, retry_after}} -> {:snooze, retry_after}
#         end
#       end
#     end
