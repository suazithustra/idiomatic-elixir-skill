# lib/my_app/rate_limiter.ex
defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  60-second window.

  Limits are read once, when the limiter starts, from a JSON file:

      {
        "default": 60,
        "users": {
          "42": 600,
          "1337": 0
        }
      }

  `"default"` applies to every user not listed under `"users"`. User ids are
  compared as strings, so `42` and `"42"` are the same user. A limit of 0
  blocks the user. If the file is missing or malformed the limiter refuses to
  start, so the application does not boot without limits.

  ## Usage

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end

  ## How it works

  Each request is a row `{user, timestamp, unique}` in a public ETS (Erlang
  Term Storage, an in-memory table shared between processes) table.
  `check/1` runs in the caller's process: it inserts a row for this request,
  counts the user's rows from the last 60 seconds and, if the count is over
  the limit, deletes its own row and refuses. Because every request records
  itself before counting, concurrent requests cannot all slip under the
  limit: no more than N are ever admitted per window. During a concurrent
  burst right at the limit it can refuse a request that would have fit.

  The GenServer only owns the tables and deletes expired rows once a minute.
  It is not on the request path, so checks from controllers and jobs run in
  parallel rather than queuing behind one process.

  Counts live in memory on one node. A restart of the limiter clears them,
  and in a cluster of K nodes a user can make up to K × N requests a minute.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @hits __MODULE__.Hits
  @limits __MODULE__.Limits

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter. `:path` (required) is the JSON limits file.
  """
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, path, name: __MODULE__)
  end

  @doc """
  Records a request for `user_id`.

  Returns `:ok` if the request is within the user's limit. Otherwise returns
  `{:error, {:rate_limited, retry_after_ms}}`, where `retry_after_ms` is the
  time until the oldest request in the window expires and frees a slot. A
  refused request does not count against the user.
  """
  @spec check(user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id) when is_integer(user_id) or is_binary(user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms
    row = {user, now, :erlang.unique_integer()}

    :ets.insert(@hits, {row})

    if :ets.select_count(@hits, in_window(user, window_start, true)) <= limit(user) do
      :ok
    else
      :ets.delete(@hits, row)
      {:error, {:rate_limited, retry_after(user, window_start, now)}}
    end
  end

  # Match spec for the user's rows newer than `window_start`. The user is a
  # bound prefix of the key, so ETS only walks that user's rows.
  defp in_window(user, window_start, result) do
    [{{{user, :"$1", :_}}, [{:>, :"$1", window_start}], [result]}]
  end

  defp limit(user) do
    case :ets.lookup(@limits, user) do
      [{^user, limit}] -> limit
      [] -> :ets.lookup_element(@limits, :default, 2)
    end
  end

  # An ordered_set returns rows in key order, so the first one is the oldest.
  defp retry_after(user, window_start, now) do
    case :ets.select(@hits, in_window(user, window_start, :"$1"), 1) do
      {[oldest], _continuation} -> oldest + @window_ms - now
      :"$end_of_table" -> @window_ms
    end
  end

  @impl true
  def init(path) do
    {default, users} = read_limits!(path)

    :ets.new(@limits, [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(@limits, [{:default, default} | Map.to_list(users)])

    :ets.new(@hits, [:ordered_set, :public, :named_table, write_concurrency: true])

    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    window_start = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(@hits, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", window_start}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)

  defp read_limits!(path) do
    case path |> File.read!() |> JSON.decode!() do
      %{"default" => default} = config ->
        users = Map.get(config, "users", %{})

        if not is_map(users) do
          raise ArgumentError, ~s(#{path}: "users" must be an object, got: #{inspect(users)})
        end

        validate_limit!(path, "default", default)
        Enum.each(users, fn {user, limit} -> validate_limit!(path, "user #{user}", limit) end)
        {default, users}

      _ ->
        raise ArgumentError, ~s(#{path}: expected an object with a "default" limit)
    end
  end

  defp validate_limit!(path, who, limit) do
    if not (is_integer(limit) and limit >= 0) do
      raise ArgumentError,
            "#{path}: limit for #{who} must be a non-negative integer, got: #{inspect(limit)}"
    end
  end
end

# ---------------------------------------------------------------------------
# Example callers. In the application each module lives in its own file (the
# path is in the comment above it). They need Phoenix, Plug and Oban.
# ---------------------------------------------------------------------------

# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MyApp.Repo,
      # Children start in order. Starting the limiter before Oban and the
      # endpoint means its tables exist before any job or request calls it.
      {MyApp.RateLimiter, path: Application.app_dir(:my_app, "priv/rate_limits.json")},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# lib/my_app_web/plugs/rate_limit.ex
defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Halts with 429 Too Many Requests when the current user is over their limit.
  Reads `conn.assigns.current_user`, so plug it after authentication.
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
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end
end

# lib/my_app_web/controllers/report_controller.ex
defmodule MyAppWeb.ReportController do
  use MyAppWeb, :controller

  # Runs before the action; a refused request never reaches create/2.
  plug MyAppWeb.Plugs.RateLimit when action in [:create]

  def create(conn, %{"report" => report_params}) do
    {:ok, report} = MyApp.Reports.create_report(conn.assigns.current_user, report_params)

    conn
    |> put_status(:created)
    |> json(%{id: report.id})
  end
end

# lib/my_app/workers/sync_account.ex
defmodule MyApp.Workers.SyncAccount do
  use Oban.Worker, queue: :default

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok ->
        MyApp.Accounts.sync(user_id)

      # Snoozing reschedules the job without using up one of its attempts.
      {:error, {:rate_limited, retry_after_ms}} ->
        {:snooze, ceil(retry_after_ms / 1000)}
    end
  end
end
