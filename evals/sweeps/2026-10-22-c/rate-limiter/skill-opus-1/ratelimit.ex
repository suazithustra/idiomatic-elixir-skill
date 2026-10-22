defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter over a rolling one-minute window.

  Each user may make at most N requests in any 60-second window. N comes
  from a limits file read once, when the limiter starts. The file holds
  Erlang terms, one per line, each ending with a period:

      {default_limit, 60}.
      {user_limit, <<"user-42">>, 600}.
      {user_limit, 1017, 5}.

  `default_limit` is required and applies to every user without a
  `user_limit` entry.

  The limiter keeps its data in an ETS table owned by this process, and
  `hit/2` runs in the caller's process, so controllers and jobs check the
  limit concurrently instead of queueing in one mailbox. Each accepted
  request is one row; a periodic sweep deletes rows older than the window.

  ## Starting

  Add it to the application's supervision tree:

      {MyApp.RateLimiter, config_path: "/etc/my_app/rate_limits.config"}
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @type user_id :: term()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path of the limits file. Required.
    * `:name` - name of the process and its ETS table. Defaults to
      `MyApp.RateLimiter`.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed and `{:error, :rate_limited}`
  when the user has already made their limit of requests in the last
  minute. Rejected requests do not count against the limit.
  """
  @spec hit(GenServer.name(), user_id()) :: :ok | {:error, :rate_limited}
  def hit(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    row_key = {:hit, user_id, now, :erlang.unique_integer()}

    # Inserting before counting keeps the check atomic without going through
    # the owner process. Two requests racing for the last slot may both be
    # rejected, but the limit is never exceeded.
    true = :ets.insert(name, {row_key})

    if recent_hit_count(name, user_id, now) <= limit(name, user_id) do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, :rate_limited}
    end
  end

  @doc """
  Returns the number of requests per minute allowed for `user_id`.
  """
  @spec limit(GenServer.name(), user_id()) :: pos_integer()
  def limit(name \\ __MODULE__, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp recent_hit_count(name, user_id, now) do
    cutoff = now - @window_ms
    match_spec = [{{{:hit, user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        create_table(name, limits)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, config_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:hit, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, match_spec)
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp create_table(name, limits) do
    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    ^name = :ets.new(name, table_options)
    true = :ets.insert(name, {:default_limit, limits.default})
    user_rows = Enum.map(limits.users, fn {user_id, n} -> {{:limit, user_id}, n} end)
    true = :ets.insert(name, user_rows)
  end

  defp load_limits(path) do
    with {:ok, terms} <- consult(path),
         {:ok, entries} <- parse_entries(terms),
         {:ok, default} <- default_limit(entries) do
      users = for {:user_limit, user_id, n} <- entries, do: {user_id, n}
      {:ok, %{default: default, users: users}}
    end
  end

  defp consult(path) do
    case :file.consult(path) do
      {:ok, terms} -> {:ok, terms}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp parse_entries(terms) do
    Enum.reduce_while(terms, {:ok, []}, fn term, {:ok, entries} ->
      case parse_entry(term) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_entry({:default_limit, n} = entry) when is_integer(n) and n > 0, do: {:ok, entry}
  defp parse_entry({:default_limit, n}), do: {:error, {:invalid_default_limit, n}}

  defp parse_entry({:user_limit, _user_id, n} = entry) when is_integer(n) and n > 0 do
    {:ok, entry}
  end

  defp parse_entry({:user_limit, user_id, n}), do: {:error, {:invalid_user_limit, user_id, n}}
  defp parse_entry(term), do: {:error, {:unknown_entry, term}}

  defp default_limit(entries) do
    defaults = for {:default_limit, n} <- entries, do: n

    case defaults do
      [n] -> {:ok, n}
      [] -> {:error, :missing_default_limit}
      [_ | _] -> {:error, :duplicate_default_limit}
    end
  end
end

# --- How it is started (lib/my_app/application.ex) ---

defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    rate_limits_path = Application.fetch_env!(:my_app, :rate_limits_path)

    children = [
      MyApp.Repo,
      {MyApp.RateLimiter, config_path: rate_limits_path},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# config/runtime.exs:
#
#     config :my_app, :rate_limits_path, System.fetch_env!("RATE_LIMITS_PATH")

# --- Callers ---

defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Rejects requests from users over their rate limit with 429.

  Add it to a pipeline after authentication, which assigns `:current_user`:

      pipeline :api do
        plug :accepts, ["json"]
        plug MyAppWeb.Plugs.Authenticate
        plug MyAppWeb.Plugs.RateLimit
      end
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case MyApp.RateLimiter.hit(conn.assigns.current_user.id) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end
end

defmodule MyAppWeb.ExportController do
  use MyAppWeb, :controller

  alias MyApp.Exports

  def create(conn, %{"format" => format}) do
    user = conn.assigns.current_user

    case MyApp.RateLimiter.hit(user.id) do
      :ok ->
        {:ok, export} = Exports.start_export(user, format)
        json(conn, %{id: export.id})

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded, try again in a minute"})
    end
  end
end

defmodule MyApp.Workers.SyncAccount do
  @moduledoc false

  use Oban.Worker, queue: :sync

  alias MyApp.Accounts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case MyApp.RateLimiter.hit(user_id) do
      :ok -> Accounts.sync(user_id)
      {:error, :rate_limited} -> {:snooze, 60}
    end
  end
end
