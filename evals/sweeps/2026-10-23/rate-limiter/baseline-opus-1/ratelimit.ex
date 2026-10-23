defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  60-second window.

  Limits are read once, from a JSON file, when the limiter starts:

      {
        "default_limit": 60,
        "users": [
          {"id": 42, "limit": 600},
          {"id": "batch-importer", "limit": 5000}
        ]
      }

  Users not listed get `default_limit`. A limit of 0 blocks the user. If the
  file is missing or malformed the limiter fails to start, so the application
  does not boot with unknown limits.

  `check/2` runs in the caller's process and only touches ETS (Erlang Term
  Storage, an in-memory table shared between processes), so controllers and
  jobs never queue behind a single process. The GenServer owns the table and
  deletes expired entries once a minute.

  Counts live in memory on each node. With several nodes behind a load
  balancer, a user can make up to N requests per minute on each node, and
  counts reset if the limiter restarts.

  ## Starting it

  Add it to the supervision tree in `lib/my_app/application.ex`, before the
  endpoint and any job queue, so it is running before the first caller:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the JSON limits file.
    * `:name` - defaults to `#{inspect(__MODULE__)}`. Pass the same name to
      `check/2` when running more than one limiter, for example in tests.
  """
  def start_link(opts) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Counts a request for `user_id` and returns `:ok` if it is within the user's
  limit for the last 60 seconds.

  Otherwise returns `{:error, {:rate_limited, retry_after_ms}}`, where
  `retry_after_ms` is the time until the oldest counted request leaves the
  window. Denied requests are not counted.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(limiter \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    {table, limits, default_limit} = :persistent_term.get({__MODULE__, limiter})
    limit = Map.get(limits, user_id, default_limit)
    now = System.monotonic_time(:millisecond)
    cutoff = now - @window_ms
    key = {user_id, now, System.unique_integer()}

    # Insert before counting. Two concurrent requests near the limit may then
    # both be denied, but the limit is never exceeded, which counting first
    # and inserting afterwards would allow.
    :ets.insert(table, {key})

    if :ets.select_count(table, in_window(user_id, cutoff, true)) <= limit do
      :ok
    else
      :ets.delete(table, key)
      {:error, {:rate_limited, retry_after(table, user_id, cutoff)}}
    end
  end

  # Entries are {{user_id, monotonic_ms, unique}}. In an ordered_set, a pattern
  # with user_id bound only walks that user's entries, oldest first.
  defp in_window(user_id, cutoff, result) do
    [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [result]}]
  end

  defp retry_after(table, user_id, cutoff) do
    case :ets.select(table, in_window(user_id, cutoff, :"$1"), 1) do
      {[oldest], _continuation} -> oldest - cutoff
      # Only reachable with a limit of 0.
      :"$end_of_table" -> @window_ms
    end
  end

  @impl true
  def init(opts) do
    {default_limit, limits} = opts |> Keyword.fetch!(:config_path) |> load_config!()
    table = :ets.new(__MODULE__, [:ordered_set, :public, write_concurrency: true])
    :persistent_term.put({__MODULE__, opts[:name]}, {table, limits, default_limit})
    schedule_sweep()
    {:ok, table}
  end

  @impl true
  def handle_info(:sweep, table) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(table, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, table}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_config!(path) do
    case path |> File.read!() |> JSON.decode!() do
      %{"default_limit" => default, "users" => users}
      when is_integer(default) and default >= 0 and is_list(users) ->
        {default, Map.new(users, &parse_user!/1)}

      _ ->
        raise ArgumentError,
              "#{path}: expected {\"default_limit\": <integer>, \"users\": [...]}"
    end
  end

  defp parse_user!(%{"id" => id, "limit" => limit})
       when (is_integer(id) or is_binary(id)) and is_integer(limit) and limit >= 0,
       do: {id, limit}

  defp parse_user!(entry),
    do: raise(ArgumentError, "invalid rate limit entry: #{inspect(entry)}")
end

# ---------------------------------------------------------------------------
# Example callers. These need Phoenix/Plug and Oban, so they do not compile on
# their own.
# ---------------------------------------------------------------------------

defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Responds 429 Too Many Requests when the logged-in user is over their limit.
  Place it after authentication, in a router pipeline or a controller:

      plug MyAppWeb.Plugs.RateLimit when action in [:create, :update]

  Requests without a logged-in user pass through unchecked.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_scope: %{user: %{id: user_id}}}} = conn, _opts) do
    case MyApp.RateLimiter.check(user_id) do
      :ok ->
        conn

      {:error, {:rate_limited, retry_after_ms}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
        |> send_resp(:too_many_requests, "Too Many Requests")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end

defmodule MyApp.Workers.SyncAccount do
  @moduledoc "Background job that checks the limiter and snoozes when over the limit."

  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> MyApp.Accounts.sync(user_id)
      {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms + 999, 1000)}
    end
  end
end
