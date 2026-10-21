defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  60-second window.

  Limits are read once, from a JSON file, when the limiter starts:

      {
        "default": 60,
        "users": {"42": 600, "1337": 5}
      }

  `"default"` applies to every user not listed under `"users"`. User ids are
  compared as strings, so `42` and `"42"` are the same user. A missing or
  malformed file makes the limiter, and so the application, fail to start.

  The window is exact, not an approximation: the limiter keeps the timestamp of
  each allowed request from the last minute. Users are spread over one process
  per scheduler, always the same process for a given user, so checks for one
  user are serialized while checks for different users run in parallel.

  Counts live in memory on the local node and are lost on restart. In a cluster
  each node enforces the limit separately.
  """

  use Supervisor

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter.

  Options:

    * `:limits_file` (required) - path to the JSON limits file.
    * `:name` - defaults to `#{inspect(__MODULE__)}`; pass the same name to
      `check/2`.
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Checks whether `user_id` may make a request now, and counts it if so.

  Returns `:ok` when the request may go ahead, or
  `{:error, {:rate_limited, retry_after_ms}}` when the user is at their limit.
  A refused request is not counted. `retry_after_ms` is the time until the
  oldest request in the window expires and a slot frees up.
  """
  @spec check(user_id(), atom()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, name \\ __MODULE__) when is_binary(user_id) or is_integer(user_id) do
    user = to_string(user_id)
    %{partitions: partitions, default: default, users: limits} = :persistent_term.get({__MODULE__, name})
    limit = Map.get(limits, user, default)

    GenServer.call({:via, PartitionSupervisor, {partitions, user}}, {:check, user, limit})
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    partitions = Module.concat(name, Partitions)
    limits = opts |> Keyword.fetch!(:limits_file) |> load_limits!()

    # Read on every check and written only here, which is the access pattern
    # :persistent_term is built for.
    :persistent_term.put({__MODULE__, name}, Map.put(limits, :partitions, partitions))

    children = [
      {PartitionSupervisor, child_spec: MyApp.RateLimiter.Partition, name: partitions}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp load_limits!(path) do
    case path |> File.read!() |> JSON.decode!() do
      %{"default" => default} = config ->
        users = Map.get(config, "users", %{})
        validate_limit!(path, "default", default)
        Enum.each(users, fn {user, limit} -> validate_limit!(path, user, limit) end)
        %{default: default, users: users}

      _ ->
        raise ArgumentError, ~s(#{path}: expected {"default": N, "users": {"<user id>": N}})
    end
  end

  defp validate_limit!(_path, _key, limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(path, key, limit) do
    raise ArgumentError,
          "#{path}: limit for #{inspect(key)} must be a positive integer, got: #{inspect(limit)}"
  end
end

defmodule MyApp.RateLimiter.Partition do
  @moduledoc false
  # Holds the request log for the users routed to this partition:
  # %{user => {count, queue of monotonic timestamps in ms, oldest first}}.

  use GenServer

  @window_ms :timer.minutes(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:check, user, limit}, _from, users) do
    now = System.monotonic_time(:millisecond)
    {count, log} = users |> Map.get(user, {0, :queue.new()}) |> expire(now - @window_ms)

    if count < limit do
      {:reply, :ok, Map.put(users, user, {count + 1, :queue.in(now, log)})}
    else
      retry_after_ms = :queue.head(log) + @window_ms - now
      {:reply, {:error, {:rate_limited, retry_after_ms}}, Map.put(users, user, {count, log})}
    end
  end

  # Forget users with no requests in the last window, so memory tracks active
  # users rather than every user ever seen.
  @impl true
  def handle_info(:sweep, users) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    schedule_sweep()
    {:noreply, Map.reject(users, fn {_user, {_count, log}} -> :queue.last(log) <= cutoff end)}
  end

  defp expire({count, log}, cutoff) do
    case :queue.peek(log) do
      {:value, oldest} when oldest <= cutoff -> expire({count - 1, :queue.drop(log)}, cutoff)
      _ -> {count, log}
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)
end

# -----------------------------------------------------------------------------
# Starting it, and callers. The callers need Plug, Phoenix and Oban, so they do
# not compile here. In a real app each module below lives in its own file.
# -----------------------------------------------------------------------------

# priv/rate_limits.json
#
#     {"default": 60, "users": {"42": 600, "1337": 5}}

# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      # Before the endpoint and Oban, which call it.
      {MyApp.RateLimiter, limits_file: Application.app_dir(:my_app, "priv/rate_limits.json")},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# lib/my_app_web/plugs/rate_limit.ex
defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Responds 429 Too Many Requests when the signed-in user is over their limit.
  Must run after the plug that assigns `:current_user`.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
      :ok ->
        conn

      {:error, {:rate_limited, retry_after_ms}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
        |> send_resp(:too_many_requests, "Too Many Requests")
        |> halt()
    end
  end
end

# lib/my_app_web/controllers/report_controller.ex
defmodule MyAppWeb.ReportController do
  use MyAppWeb, :controller

  plug MyAppWeb.Plugs.RateLimit when action in [:create]

  def create(conn, %{"report" => report_params}) do
    {:ok, report} = MyApp.Reports.create(conn.assigns.current_user, report_params)
    render(conn, :show, report: report)
  end
end

# lib/my_app/workers/export_worker.ex
defmodule MyApp.Workers.ExportWorker do
  use Oban.Worker, queue: :exports

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "report_id" => report_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> MyApp.Reports.export(user_id, report_id)
      # Put the job back and retry once a slot frees up, without using up an attempt.
      {:error, {:rate_limited, retry_after_ms}} -> {:snooze, ceil(retry_after_ms / 1000)}
    end
  end
end
