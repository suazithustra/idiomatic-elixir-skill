defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests per rolling minute.

  Limits come from an Elixir script file read once, when the limiter starts. The
  file evaluates to a map with a `:default` limit and optional per-user `:users`
  overrides:

      %{
        default: 60,
        users: %{"user-1" => 600, "user-2" => 10}
      }

  Every request is recorded as a row in a public ETS table owned by this process.
  Callers check the limit from their own process with `check/2`, so the GenServer
  is not a bottleneck. A request is recorded first and counted afterwards, and the
  row is deleted again when the count is over the limit, so concurrent callers
  cannot exceed the limit by racing between a read and a write. User ids should be
  integers or binaries.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and the job
  runner, so every caller finds it running:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.create(conn.assigns.current_user, params)
              render(conn, :show, report: report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> put_resp_header("retry-after", "60")
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.SyncAccount do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Accounts.sync(user_id)
            {:error, :rate_limited} -> {:snooze, 60}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: integer() | binary()

  @doc """
  Starts the limiter and loads the limits from the file at `:path`.

  Raises, and so fails the supervisor start, when the file is missing or
  malformed: a limiter without limits must not start.

  ## Options

    * `:path` - the limits file. Required.
    * `:name` - the process name, which is also the name of its ETS table.
      Defaults to `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:path, name: __MODULE__])
    path = Keyword.fetch!(opts, :path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, path}, name: name)
  end

  @doc """
  Records a request for `user_id` and returns `:ok` while the user is within the
  limit for the last minute, or `{:error, :rate_limited}` once it is over.

  A rejected request is not counted against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, :erlang.unique_integer([:monotonic])}
    :ets.insert(name, {key})

    if count_since(name, user_id, now - @window_ms) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @doc """
  Returns the number of requests `user_id` may still make in the current minute.
  """
  @spec remaining(atom(), user_id()) :: non_neg_integer()
  def remaining(name \\ __MODULE__, user_id) do
    used = count_since(name, user_id, System.monotonic_time(:millisecond) - @window_ms)
    max(limit_for(name, user_id) - used, 0)
  end

  @impl true
  def init({name, path}) do
    limits = load_limits!(path)
    :persistent_term.put({__MODULE__, name}, limits)

    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  @impl true
  def terminate(_reason, name) do
    :persistent_term.erase({__MODULE__, name})
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp limit_for(name, user_id) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user_id, default)
  end

  defp load_limits!(path) do
    {limits, _bindings} = Code.eval_file(path)
    %{default: default} = limits
    users = Map.get(limits, :users, %{})

    validate_limit!(:default, default)
    Enum.each(users, fn {user_id, limit} -> validate_limit!(user_id, limit) end)

    %{default: default, users: users}
  end

  defp validate_limit!(_owner, limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(owner, limit) do
    raise ArgumentError,
          "rate limit for #{inspect(owner)} must be a positive integer, got: #{inspect(limit)}"
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
