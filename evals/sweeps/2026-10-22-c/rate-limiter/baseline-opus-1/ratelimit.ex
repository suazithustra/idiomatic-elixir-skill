defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user sliding-window rate limiter.

  Each user may make at most N requests in any rolling 60-second window. N is
  read per user from a JSON file when the limiter starts:

      {
        "default_limit": 60,
        "users": {
          "42": 600,
          "1337": 5
        }
      }

  Users not listed get `default_limit`. User ids are compared as strings, so
  `check(42)` and `check("42")` refer to the same user.

  ## Design

  The limit is exact (no fixed-bucket approximation): for every user we keep
  the timestamps of the requests admitted in the last minute. To avoid a single
  process becoming a bottleneck, state is spread over a `PartitionSupervisor`
  with one `MyApp.RateLimiter.Partition` per scheduler; a given user always
  hashes to the same partition, so checks for one user are serialized (no
  races) while different users are checked in parallel.

  ## Starting

  Add it to your application's supervision tree, before the endpoint and any
  job processors that call it:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint,
        {Oban, Application.fetch_env!(:my_app, Oban)}
      ]

  ## Calling

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end
  """

  use Supervisor

  alias MyApp.RateLimiter.Partition

  @window_ms 60_000

  @type user_id :: String.t() | integer()
  @type check_result :: :ok | {:error, {:rate_limited, retry_after_ms :: pos_integer()}}

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the JSON limits file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
    * `:partitions` - number of partitions, defaults to `System.schedulers_online/0`
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within the user's limit.

  Returns `:ok` if the request is allowed (and counts it), or
  `{:error, {:rate_limited, retry_after_ms}}` if the user has already made
  their limit of requests in the last minute. Rejected requests are not
  counted.
  """
  @spec check(user_id(), atom()) :: check_result()
  def check(user_id, name \\ __MODULE__) do
    user_id = to_string(user_id)

    GenServer.call(
      {:via, PartitionSupervisor, {partition_supervisor(name), user_id}},
      {:check, user_id}
    )
  end

  @impl Supervisor
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    limits = opts |> Keyword.fetch!(:config_path) |> load_limits!()

    children = [
      {PartitionSupervisor,
       child_spec: {Partition, limits: limits, window_ms: @window_ms},
       name: partition_supervisor(name),
       partitions: Keyword.get(opts, :partitions, System.schedulers_online())}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp partition_supervisor(name), do: Module.concat(name, Partitions)

  @doc false
  def load_limits!(path) do
    config = path |> File.read!() |> JSON.decode!()

    default = Map.fetch!(config, "default_limit")
    validate_limit!(default, "default_limit")

    users =
      config
      |> Map.get("users", %{})
      |> Map.new(fn {user_id, limit} ->
        validate_limit!(limit, "users.#{user_id}")
        {user_id, limit}
      end)

    %{default: default, users: users}
  end

  defp validate_limit!(limit, _key) when is_integer(limit) and limit >= 0, do: :ok

  defp validate_limit!(limit, key) do
    raise ArgumentError,
          "rate limit #{key} must be a non-negative integer, got: #{inspect(limit)}"
  end
end

defmodule MyApp.RateLimiter.Partition do
  @moduledoc false
  # Owns the request history for the subset of users that hash to it.
  # State: %{user_id => {count, :queue.queue(timestamp_ms)}}, oldest first.

  use GenServer

  @sweep_interval_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    schedule_sweep()

    {:ok,
     %{
       limits: Keyword.fetch!(opts, :limits),
       window_ms: Keyword.fetch!(opts, :window_ms),
       users: %{}
     }}
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits.users, user_id, state.limits.default)

    {count, queue} =
      state.users
      |> Map.get(user_id, {0, :queue.new()})
      |> drop_expired(now - state.window_ms)

    if count < limit do
      users = Map.put(state.users, user_id, {count + 1, :queue.in(now, queue)})
      {:reply, :ok, %{state | users: users}}
    else
      {:reply, {:error, {:rate_limited, retry_after(queue, now, state.window_ms)}},
       %{state | users: store(state.users, user_id, count, queue)}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - state.window_ms

    users =
      Enum.reduce(state.users, %{}, fn {user_id, entry}, acc ->
        {count, queue} = drop_expired(entry, cutoff)
        store(acc, user_id, count, queue)
      end)

    schedule_sweep()
    {:noreply, %{state | users: users}}
  end

  defp drop_expired({count, queue} = entry, cutoff) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= cutoff -> drop_expired({count - 1, :queue.drop(queue)}, cutoff)
      _ -> entry
    end
  end

  # A limit of 0 leaves the queue empty; there is no request whose expiry would
  # free a slot, so tell the caller to wait a full window.
  defp retry_after(queue, now, window_ms) do
    case :queue.peek(queue) do
      {:value, oldest} -> max(oldest + window_ms - now, 1)
      :empty -> window_ms
    end
  end

  defp store(users, user_id, 0, _queue), do: Map.delete(users, user_id)
  defp store(users, user_id, count, queue), do: Map.put(users, user_id, {count, queue})

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

# ---------------------------------------------------------------------------
# Example callers (require Phoenix / Oban, so they are not compiled here).
# ---------------------------------------------------------------------------
#
# A plug shared by any controller or pipeline that needs limiting:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(%Plug.Conn{assigns: %{current_user: %{id: user_id}}} = conn, _opts) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok ->
#             conn
#
#           {:error, {:rate_limited, retry_after_ms}} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
#             |> put_status(:too_many_requests)
#             |> Phoenix.Controller.json(%{error: "rate limit exceeded"})
#             |> halt()
#         end
#       end
#     end
#
#     # in a controller:
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       plug MyAppWeb.Plugs.RateLimit when action in [:create]
#
#       def create(conn, params) do
#         report = MyApp.Reports.generate!(conn.assigns.current_user, params)
#         json(conn, report)
#       end
#     end
#
# A background job that defers itself instead of failing:
#
#     defmodule MyApp.Workers.SyncAccount do
#       use Oban.Worker, queue: :sync
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok ->
#             MyApp.Accounts.sync(user_id)
#
#           {:error, {:rate_limited, retry_after_ms}} ->
#             {:snooze, div(retry_after_ms + 999, 1000)}
#         end
#       end
#     end
