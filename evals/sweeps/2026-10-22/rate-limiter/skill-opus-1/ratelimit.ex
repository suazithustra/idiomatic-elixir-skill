# lib/my_app/rate_limiter/limit_exceeded_error.ex
defmodule MyApp.RateLimiter.LimitExceededError do
  @moduledoc """
  The reason `MyApp.RateLimiter.check/2` returns when a user is at their limit.

  `retry_after` is the number of whole seconds, rounded up, until the user's
  oldest counted request leaves the window. It fits an HTTP `retry-after`
  header or a job's snooze time.
  """

  @enforce_keys [:user_id, :limit, :retry_after]
  defexception @enforce_keys

  @type t :: %__MODULE__{
          user_id: MyApp.RateLimiter.user_id(),
          limit: pos_integer(),
          retry_after: non_neg_integer()
        }

  @impl true
  def message(error) do
    "user #{error.user_id} is at the limit of #{error.limit} requests per minute; " <>
      "retry in #{error.retry_after} s"
  end
end

# lib/my_app/rate_limiter.ex
defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a number of requests per rolling minute.

  Each user's limit comes from a JSON file read once, when the limiter
  starts. Users not listed under `"users"` get `"default_limit"`:

      {
        "default_limit": 60,
        "users": {
          "42": 600,
          "1337": 10
        }
      }

  User IDs are JSON strings in the file. `check/2` accepts integer or string
  IDs and treats `42` and `"42"` as the same user.

  Add the limiter to the supervision tree before anything that calls it:

      {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}

  `check/2` runs in the caller's process against a shared ETS (Erlang Term
  Storage) table, so checks from many controllers and jobs do not queue
  behind one process. The limiter process owns the table and deletes expired
  requests from it once a minute.

  A request is allowed when the user has made fewer than their limit of
  allowed requests in the last 60 seconds. Rejected requests are not counted.
  Each check counts the user's requests in the window, so its cost grows with
  the limit; this suits limits up to a few thousand per minute.

  Limits are per node. On a cluster of three nodes, a user can make up to
  three times their limit per minute.
  """

  use GenServer

  alias MyApp.RateLimiter.LimitExceededError

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @type user_id :: integer() | String.t()

  defguardp is_limit(value) when is_integer(value) and value > 0

  @doc """
  Starts the limiter and reads the limits file.

  Returns `{:error, reason}` when the file cannot be read or is invalid, so a
  bad file stops the application from booting.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - the atom to register the process and its ETS table under.
      Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    start_server(Keyword.fetch!(opts, :name), Keyword.fetch!(opts, :config_path))
  end

  @doc """
  Counts a request from `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed. The request then counts against
  the user's limit for the next 60 seconds.

  Returns `{:error, %LimitExceededError{}}` when the user is at their limit.
  The rejected request is not counted.

  Two checks that race for a user's last free slot may both be rejected. The
  limit is never exceeded.
  """
  @spec check(user_id()) :: :ok | {:error, LimitExceededError.t()}
  @spec check(atom(), user_id()) :: :ok | {:error, LimitExceededError.t()}
  def check(name \\ __MODULE__, user_id)
      when is_atom(name) and (is_integer(user_id) or is_binary(user_id)) do
    user_key = user_key(user_id)
    limit = limit_for(name, user_key)
    now = System.monotonic_time(:millisecond)
    request_key = {:request, user_key, now, System.unique_integer()}

    # Insert before counting, so concurrent checks for the same user count
    # each other. Counting first and inserting after would let them all pass.
    :ets.insert(name, {request_key})

    if count_in_window(name, user_key, now) <= limit do
      :ok
    else
      :ets.delete(name, request_key)

      error = %LimitExceededError{
        user_id: user_id,
        limit: limit,
        retry_after: retry_after(name, user_key, now)
      }

      {:error, error}
    end
  end

  @impl true
  def init({name, config_path}) do
    # Read here rather than in handle_continue/2: the supervisor starts the
    # callers only after init/1 returns, so the limits are in the table before
    # the first check.
    case load_limits(config_path) do
      {:ok, limits} ->
        create_table(name, limits)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, table) do
    :ets.select_delete(table, expired_spec(System.monotonic_time(:millisecond)))
    schedule_sweep()
    {:noreply, table}
  end

  defp start_server(name, config_path) when is_atom(name) and is_binary(config_path) do
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  defp user_key(user_id) when is_integer(user_id), do: Integer.to_string(user_id)
  defp user_key(user_id) when is_binary(user_id), do: user_id

  defp limit_for(table, user_key) do
    case :ets.lookup(table, {:limit, user_key}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(table, :default_limit, 2)
    end
  end

  defp count_in_window(table, user_key, now) do
    :ets.select_count(table, in_window_spec(user_key, now, true))
  end

  defp retry_after(table, user_key, now) do
    case :ets.select(table, in_window_spec(user_key, now, :"$1"), 1) do
      {[oldest], _continuation} -> seconds_rounded_up(oldest + @window - now)
      # The user's requests expired, and were swept, after they were counted.
      :"$end_of_table" -> 0
    end
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- read_config(config_path),
         {:ok, config} <- decode_config(contents),
         {:ok, default_limit} <- default_limit(config),
         {:ok, user_limits} <- user_limits(config) do
      {:ok, %{default: default_limit, users: user_limits}}
    end
  end

  defp read_config(config_path) do
    case File.read(config_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, config_path, reason}}
    end
  end

  defp decode_config(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = config} -> {:ok, config}
      {:ok, _other} -> {:error, :config_not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp default_limit(%{"default_limit" => limit}) when is_limit(limit), do: {:ok, limit}

  defp default_limit(%{"default_limit" => _limit}),
    do: {:error, {:invalid_field, "default_limit"}}

  defp default_limit(%{}), do: {:error, {:missing_field, "default_limit"}}

  defp user_limits(%{"users" => users}) when is_map(users) do
    case Enum.find(users, fn {_user_key, limit} -> not is_limit(limit) end) do
      nil -> {:ok, users}
      {user_key, _limit} -> {:error, {:invalid_user_limit, user_key}}
    end
  end

  defp user_limits(%{"users" => _users}), do: {:error, {:invalid_field, "users"}}
  defp user_limits(%{}), do: {:error, {:missing_field, "users"}}

  # The table holds three kinds of rows:
  #
  #   {:default_limit, limit}
  #   {{:limit, user_key}, limit}
  #   {{:request, user_key, timestamp, unique_integer}}, one per counted request
  #
  # An ordered_set keeps each user's requests next to each other in time
  # order, so counting them walks only that user's rows.
  defp create_table(name, limits) do
    :ets.new(name, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    user_rows = for {user_key, limit} <- limits.users, do: {{:limit, user_key}, limit}
    :ets.insert(name, [{:default_limit, limits.default} | user_rows])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  # Match specifications over request rows, where `$1` is the timestamp.
  defp in_window_spec(user_key, now, result) do
    [{{{:request, user_key, :"$1", :_}}, [{:>, :"$1", now - @window}], [result]}]
  end

  defp expired_spec(now) do
    [{{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", now - @window}], [true]}]
  end

  defp seconds_rounded_up(milliseconds), do: div(milliseconds + 999, 1000)
end

# lib/my_app/application.ex
defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      # Started before Oban and the Endpoint, so it is running before the
      # first job or request calls it.
      {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# lib/my_app_web/plugs/rate_limit.ex
defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Answers 429 Too Many Requests when the current user is at their limit.

  Plug it in after authentication, because it reads
  `conn.assigns.current_scope`.
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.RateLimiter

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RateLimiter.check(conn.assigns.current_scope.user.id) do
      :ok ->
        conn

      {:error, %RateLimiter.LimitExceededError{} = error} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(error.retry_after))
        |> send_resp(:too_many_requests, "Too Many Requests")
        |> halt()
    end
  end
end

# lib/my_app_web/controllers/search_controller.ex
defmodule MyAppWeb.SearchController do
  use MyAppWeb, :controller

  plug(MyAppWeb.Plugs.RateLimit when action in [:create])

  def create(conn, %{"query" => query}) do
    results = MyApp.Search.run(conn.assigns.current_scope, query)
    json(conn, %{results: results})
  end
end

# lib/my_app/workers/sync_contacts.ex
defmodule MyApp.Workers.SyncContacts do
  use Oban.Worker, queue: :sync

  alias MyApp.RateLimiter

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case RateLimiter.check(user_id) do
      :ok -> MyApp.Contacts.sync(user_id)
      {:error, %RateLimiter.LimitExceededError{} = error} -> {:snooze, error.retry_after}
    end
  end
end
