defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter with a rolling one-minute window.

  Each user may make at most N requests in any 60-second period. N comes from
  a limits file read once when the limiter starts. The file holds Erlang terms
  (read with `:file.consult/1`), so user IDs keep their types:

      %% priv/rate_limits.config
      {default_limit, 60}.
      {user_limit, 42, 600}.
      {user_limit, <<"service-account">>, 5000}.

  Users without a `user_limit` entry get the `default_limit`.

  Callers check the limit from their own process: every request is a row in an
  ETS table owned by this process, so checks from many controllers and jobs
  run concurrently instead of queueing on one mailbox. The process only owns
  the table and periodically deletes rows that have left the window.

  Start it in the application's supervision tree:

      children = [
        {MyApp.RateLimiter, limits_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter and reads the limits file.

  Fails to start if the file is missing or contains an entry it does not
  recognize, so a bad deploy stops at boot instead of limiting with wrong values.

  ## Options

    * `:limits_path` - path to the limits file. Required.
    * `:name` - name of the process and its ETS table. Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Records a request for `user_id` and returns `:ok` if it is within the user's
  limit, or `{:error, :rate_limited}` if the user has already made their
  allowed number of requests in the last minute.

  Rejected requests are not counted against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, :erlang.unique_integer()}

    # Insert first, then count: two concurrent checks can never both see room
    # for one more request. A lookup-then-insert would let them both through.
    :ets.insert(name, {key})

    if recent_requests(name, user_id, now) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  defp recent_requests(name, user_id, now) do
    cutoff = now - @window
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, user_id, limits.default)
  end

  @impl true
  def init(opts) do
    name = opts[:name]

    case read_limits(opts[:limits_path]) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, limits)
        create_table(name)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  @impl true
  def terminate(_reason, name) do
    :persistent_term.erase({__MODULE__, name})
  end

  # An ordered_set keeps one user's rows together, so counting them with a
  # bound user ID scans only that user's rows, not the whole table.
  defp create_table(name) do
    :ets.new(name, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp read_limits(path) when is_binary(path) do
    case :file.consult(path) do
      {:ok, entries} -> parse_limits(entries)
      {:error, reason} -> {:error, {:unreadable_limits_file, path, reason}}
    end
  end

  defp parse_limits(entries) do
    initial = {:ok, %{default: nil, users: %{}}}

    entries
    |> Enum.reduce_while(initial, fn entry, {:ok, limits} ->
      case parse_entry(entry, limits) do
        {:ok, limits} -> {:cont, {:ok, limits}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> require_default()
  end

  defp parse_entry({:default_limit, limit}, limits) when is_integer(limit) and limit >= 0 do
    {:ok, %{limits | default: limit}}
  end

  defp parse_entry({:user_limit, user_id, limit}, limits)
       when (is_integer(user_id) or is_binary(user_id)) and is_integer(limit) and limit >= 0 do
    {:ok, %{limits | users: Map.put(limits.users, user_id, limit)}}
  end

  defp parse_entry(entry, _limits), do: {:error, {:invalid_limits_entry, entry}}

  defp require_default({:ok, %{default: nil}}), do: {:error, :missing_default_limit}
  defp require_default(result), do: result
end

# ---------------------------------------------------------------------------
# Example callers. They need Phoenix and Oban, so they do not compile on their own.
# ---------------------------------------------------------------------------

defmodule MyAppWeb.ReportController do
  use MyAppWeb, :controller

  alias MyApp.Reports

  def create(conn, params) do
    user = conn.assigns.current_user

    case MyApp.RateLimiter.check(user.id) do
      :ok ->
        {:ok, report} = Reports.create_report(user, params)
        render(conn, :show, report: report)

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded"})
    end
  end
end

defmodule MyApp.Workers.SyncAccount do
  use Oban.Worker, queue: :sync

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> MyApp.Accounts.sync(user_id)
      {:error, :rate_limited} -> {:snooze, 60}
    end
  end
end
