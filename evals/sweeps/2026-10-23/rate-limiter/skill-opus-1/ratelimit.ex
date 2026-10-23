# lib/my_app/rate_limiter/limit_exceeded.ex
defmodule MyApp.RateLimiter.LimitExceeded do
  @moduledoc """
  The error `MyApp.RateLimiter.check/2` returns when a user is over their limit.

  `:retry_after` is the number of seconds, rounded up, until the user's oldest
  counted request leaves the one-minute window.
  """

  defexception [:user_id, :limit, :retry_after]

  @type t :: %__MODULE__{
          user_id: integer(),
          limit: pos_integer(),
          retry_after: pos_integer()
        }

  @impl true
  def message(error) do
    "user #{error.user_id} is over the rate limit of #{error.limit} per minute"
  end
end

# lib/my_app/rate_limiter/limits.ex
defmodule MyApp.RateLimiter.Limits do
  @moduledoc false

  @enforce_keys [:default, :per_user]
  defstruct [:default, :per_user]

  @type t :: %__MODULE__{
          default: pos_integer(),
          per_user: %{optional(integer()) => pos_integer()}
        }

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, json} <- read_file(path),
         {:ok, decoded} <- decode_json(json) do
      parse(decoded)
    end
  end

  @spec limit_for(t(), integer()) :: pos_integer()
  def limit_for(%__MODULE__{} = limits, user_id) do
    Map.get(limits.per_user, user_id, limits.default)
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:unreadable_limits_file, path, reason}}
    end
  end

  defp decode_json(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse(%{"default" => default, "users" => users}) when is_map(users) do
    with {:ok, default} <- parse_limit(default),
         {:ok, per_user} <- parse_users(users) do
      {:ok, %__MODULE__{default: default, per_user: per_user}}
    end
  end

  defp parse(_decoded), do: {:error, :invalid_limits_file}

  defp parse_users(users) do
    Enum.reduce_while(users, {:ok, %{}}, &put_user_limit/2)
  end

  defp put_user_limit({key, limit}, {:ok, per_user}) do
    case parse_user(key, limit) do
      {:ok, {user_id, limit}} -> {:cont, {:ok, Map.put(per_user, user_id, limit)}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp parse_user(key, limit) do
    with {:ok, user_id} <- parse_user_id(key),
         {:ok, limit} <- parse_limit(limit) do
      {:ok, {user_id, limit}}
    end
  end

  defp parse_user_id(key) do
    case Integer.parse(key) do
      {user_id, ""} -> {:ok, user_id}
      {_user_id, _rest} -> {:error, {:invalid_user_id, key}}
      :error -> {:error, {:invalid_user_id, key}}
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp parse_limit(limit), do: {:error, {:invalid_limit, limit}}
end

# lib/my_app/rate_limiter.ex
defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user at most a set number of requests per rolling minute.

  The limits come from a JSON file, read when the limiter starts:

      {
        "default": 60,
        "users": {"42": 600, "1007": 10}
      }

  A user listed under `"users"` by integer user ID gets that limit; every
  other user gets `"default"`. Edits to the file take effect when the limiter
  restarts.

  `check/2` runs in the caller's process against an ETS table, so controllers
  and jobs do not queue behind one process. The limiter process owns the table
  and deletes rows older than a minute.

  Counts are kept per node: in a cluster of three nodes, a user can make up to
  three times their limit.
  """

  use GenServer

  alias MyApp.RateLimiter.LimitExceeded
  alias MyApp.RateLimiter.Limits

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @doc """
  Starts the limiter and reads the limits file.

  The limiter does not start when the file is missing or invalid, so a bad
  file stops the application at boot instead of failing requests later.

  ## Options

    * `:limits_path` - path of the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to
      `MyApp.RateLimiter`; tests can start their own instance under another name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    limits_path = Keyword.fetch!(opts, :limits_path)
    GenServer.start_link(__MODULE__, {name, limits_path}, name: name)
  end

  @doc """
  Counts a request by the user and returns `:ok` if they are within their
  limit for the last minute.

  A refused request is not counted, so a user who keeps retrying while over
  the limit gets through as soon as their earlier requests age out.
  """
  @spec check(atom(), integer()) :: :ok | {:error, LimitExceeded.t()}
  def check(name \\ __MODULE__, user_id) when is_atom(name) and is_integer(user_id) do
    now = System.monotonic_time(:millisecond)
    limit = limit_for(name, user_id)
    row_key = {user_id, now, System.unique_integer()}

    # Insert before counting so that concurrent requests see each other's rows
    # and together never pass the limit; at worst they are all refused.
    :ets.insert(name, {row_key})

    if count_in_window(name, user_id, now) <= limit do
      :ok
    else
      refuse(name, row_key, limit)
    end
  end

  @impl true
  def init({name, limits_path}) do
    # Read here rather than in handle_continue/2 so that the table, and with
    # it check/2, never exists without limits.
    case Limits.load(limits_path) do
      {:ok, limits} ->
        # Every check reads the limits and they never change while the
        # limiter runs, which is the case :persistent_term is built for.
        :persistent_term.put({__MODULE__, name}, limits)
        create_table(name)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, table) do
    cutoff = System.monotonic_time(:millisecond) - @window
    expired = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(table, expired)
    schedule_sweep()
    {:noreply, table}
  end

  defp limit_for(name, user_id) do
    limits = :persistent_term.get({__MODULE__, name})
    Limits.limit_for(limits, user_id)
  end

  defp count_in_window(table, user_id, now) do
    in_window = [{{{user_id, :"$1", :_}}, [{:>, :"$1", now - @window}], [true]}]
    :ets.select_count(table, in_window)
  end

  defp refuse(table, {user_id, now, _unique} = row_key, limit) do
    retry_after = seconds_until_oldest_expires(table, user_id, now)
    :ets.delete(table, row_key)
    {:error, %LimitExceeded{user_id: user_id, limit: limit, retry_after: retry_after}}
  end

  # The caller's own row is still in the table, so there is always a match.
  # An ordered_set returns rows in key order, so the first match is the oldest.
  defp seconds_until_oldest_expires(table, user_id, now) do
    times_in_window = [{{{user_id, :"$1", :_}}, [{:>, :"$1", now - @window}], [:"$1"]}]
    {[oldest], _continuation} = :ets.select(table, times_in_window, 1)
    milliseconds_left = oldest + @window - now
    div(milliseconds_left + 999, 1000)
  end

  defp create_table(name) do
    # Rows are keyed {user_id, time, unique}. In an ordered_set, a select with
    # the user ID bound visits only that user's rows, not the whole table.
    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end

# lib/my_app/application.ex
defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    limits_path = Application.app_dir(:my_app, "priv/rate_limits.json")

    children = [
      MyApp.Repo,
      # Started before, and stopped after, Oban and the endpoint, which call it.
      {MyApp.RateLimiter, limits_path: limits_path},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

# lib/my_app_web/plugs/rate_limit.ex
defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Refuses the request with 429 Too Many Requests when the signed-in user is
  over their rate limit.

  Plug it in after authentication, in a router pipeline or in a controller:

      plug MyAppWeb.Plugs.RateLimit when action in [:create, :update]
  """

  @behaviour Plug

  import Plug.Conn

  alias MyApp.RateLimiter
  alias MyApp.RateLimiter.LimitExceeded

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RateLimiter.check(conn.assigns.current_scope.user.id) do
      :ok ->
        conn

      {:error, %LimitExceeded{} = error} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(error.retry_after))
        |> send_resp(:too_many_requests, Exception.message(error))
        |> halt()
    end
  end
end

# lib/my_app/workers/report_export.ex
defmodule MyApp.Workers.ReportExport do
  @moduledoc """
  Exports a report for a user. The export counts against the user's rate
  limit; when the user is over it, the job waits until they have room again.
  """

  use Oban.Worker, queue: :exports

  alias MyApp.RateLimiter
  alias MyApp.RateLimiter.LimitExceeded
  alias MyApp.Reports

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "report_id" => report_id}}) do
    case RateLimiter.check(user_id) do
      :ok -> Reports.export_report(user_id, report_id)
      {:error, %LimitExceeded{retry_after: seconds}} -> {:snooze, seconds}
    end
  end
end
