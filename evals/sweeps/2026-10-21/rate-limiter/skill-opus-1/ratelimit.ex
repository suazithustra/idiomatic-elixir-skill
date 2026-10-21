# lib/my_app/rate_limiter/limit_exceeded_error.ex
defmodule MyApp.RateLimiter.LimitExceededError do
  @moduledoc """
  The error `MyApp.RateLimiter.check/2` returns when a user is over their limit.

  `retry_after` is the number of seconds, rounded up, until the user's oldest
  counted request leaves the one-minute window. It fits both the `retry-after`
  HTTP header and Oban's `{:snooze, seconds}`.
  """

  @enforce_keys [:user_id, :limit, :retry_after]
  defexception [:user_id, :limit, :retry_after]

  @type t :: %__MODULE__{
          user_id: MyApp.RateLimiter.user_id(),
          limit: pos_integer(),
          retry_after: pos_integer()
        }

  @impl true
  def message(error) do
    "user #{error.user_id} exceeded #{error.limit} requests per minute, " <>
      "retry in #{error.retry_after}s"
  end
end

# lib/my_app/rate_limiter.ex
defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a configured number of requests per rolling minute.

  The limits come from a JSON file that is read once, when the limiter starts:

      {
        "default": 60,
        "users": {
          "42": 600,
          "1337": 10
        }
      }

  Users not listed under `"users"` get `"default"`. Every limit must be a
  positive integer. A missing or invalid file stops the limiter from starting,
  and with it the application. Changes to the file take effect when the
  limiter restarts.

  Callers write to a public ETS (Erlang Term Storage) table themselves, so
  checks from controllers and jobs run in parallel instead of waiting in one
  process's mailbox. The process only owns the table and deletes expired
  entries once a minute.

  Counts live in memory on one node. They reset when the limiter restarts, and
  in a cluster each node enforces the limit separately.
  """
  use GenServer

  alias MyApp.RateLimiter.LimitExceededError

  @window :timer.minutes(1)

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter and reads the limits file.

  ## Options

    * `:limits_path` - path to the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to
      `MyApp.RateLimiter`. Pass the same name to `check/2`, for example to
      run a separate limiter in a test.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {name, Keyword.fetch!(opts, :limits_path)}, name: name)
  end

  @doc """
  Counts a request by `user_id` against the user's limit.

  Returns `:ok` and counts the request when the user has made fewer requests
  than their limit in the last 60 seconds. Otherwise returns
  `{:error, %LimitExceededError{}}` and does not count the request, so a caller
  that is turned away and retries later is not penalized for the attempt.

  `user_id` may be an integer or a string; `42` and `"42"` are the same user.
  `name` is the `:name` given to `start_link/1`.

  When several checks for the same user arrive at the same moment at the
  limit, all of them can be rejected even though one slot was free. The limit
  itself is never exceeded.
  """
  @spec check(user_id()) :: :ok | {:error, LimitExceededError.t()}
  @spec check(atom(), user_id()) :: :ok | {:error, LimitExceededError.t()}
  def check(name \\ __MODULE__, user_id)
      when is_atom(name) and (is_integer(user_id) or is_binary(user_id)) do
    key = user_key(user_id)
    limit = limit_for(name, key)
    now = System.monotonic_time(:millisecond)
    request = {key, now, System.unique_integer()}

    # Insert before counting, so concurrent checks for one user always see
    # each other's rows. Counting first would let every check that counts
    # before the others insert get through.
    :ets.insert(name, {request})

    if count_since(name, key, now - @window) <= limit do
      :ok
    else
      :ets.delete(name, request)
      retry_after = retry_after(name, key, now)
      {:error, %LimitExceededError{user_id: user_id, limit: limit, retry_after: retry_after}}
    end
  end

  @impl true
  def init({name, limits_path}) do
    # Read the file here rather than in handle_continue/2: the supervisor waits
    # for init/1, so nothing started after the limiter can check a user before
    # the limits are loaded, and a bad file stops the boot.
    case read_limits(limits_path) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, limits)
        :ets.new(name, [:ordered_set, :named_table, :public, write_concurrency: true])
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_limits_file, limits_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, table) do
    cutoff = System.monotonic_time(:millisecond) - @window
    :ets.select_delete(table, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, table}
  end

  defp user_key(user_id) when is_integer(user_id), do: Integer.to_string(user_id)
  defp user_key(user_id) when is_binary(user_id), do: user_id

  defp limit_for(name, key) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, key, default)
  end

  defp count_since(table, key, cutoff) do
    :ets.select_count(table, [{{{key, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  # The table is an ordered set keyed by {user, time, unique}, so the first row
  # selected for a user is their oldest request still in the window.
  defp retry_after(table, key, now) do
    spec = [{{{key, :"$1", :_}}, [{:>, :"$1", now - @window}], [:"$1"]}]

    case :ets.select(table, spec, 1) do
      {[oldest_at], _continuation} -> div(oldest_at + @window - now + 999, 1000)
      # Concurrent rejected checks may have deleted every row since we counted.
      :"$end_of_table" -> 1
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window)

  defp read_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, config} <- decode_json(contents) do
      parse_limits(config)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default, "users" => users}) when is_map(users) do
    with :ok <- validate_limit("default", default),
         :ok <- validate_user_limits(users) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_config), do: {:error, :expected_default_and_users}

  defp validate_user_limits(users) do
    case Enum.find(users, fn {_user_id, limit} -> not valid_limit?(limit) end) do
      nil -> :ok
      {user_id, limit} -> {:error, {:invalid_limit, user_id, limit}}
    end
  end

  defp validate_limit(field, limit) do
    if valid_limit?(limit), do: :ok, else: {:error, {:invalid_limit, field, limit}}
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end

# lib/my_app/application.ex
defmodule MyApp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      # Started before Oban and the Endpoint, so no job or request can check a
      # limit before the table exists, and stopped after them on shutdown.
      {MyApp.RateLimiter, limits_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# lib/my_app_web/plugs/rate_limit.ex
defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Halts with `429 Too Many Requests` when the current user is over their
  rate limit.

  Plug it after authentication, in a router pipeline or in a controller:

      plug MyAppWeb.Plugs.RateLimit when action in [:create, :update]
  """
  @behaviour Plug

  import Plug.Conn

  alias MyApp.RateLimiter
  alias MyApp.RateLimiter.LimitExceededError

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RateLimiter.check(conn.assigns.current_scope.user.id) do
      :ok ->
        conn

      {:error, %LimitExceededError{retry_after: retry_after}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_resp(:too_many_requests, "Too many requests")
        |> halt()
    end
  end
end

# lib/my_app/workers/generate_report.ex
defmodule MyApp.Workers.GenerateReport do
  @moduledoc """
  Generates a report on behalf of a user, counting against the user's rate
  limit. A job over the limit is snoozed until a slot frees up instead of
  failing.
  """
  use Oban.Worker, queue: :reports

  alias MyApp.RateLimiter
  alias MyApp.RateLimiter.LimitExceededError

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "report_id" => report_id}}) do
    case RateLimiter.check(user_id) do
      :ok -> MyApp.Reports.generate(user_id, report_id)
      {:error, %LimitExceededError{retry_after: retry_after}} -> {:snooze, retry_after}
    end
  end
end
