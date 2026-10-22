defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests per rolling minute.

  N comes from a JSON file read once when the limiter starts:

      {"default": 60, "users": {"42": 600, "99": 10}}

  Users missing from `"users"` get `"default"`. User ids are matched by their
  `to_string/1` form, so `42` and `"42"` share a limit.

  A GenServer owns an ETS table and sweeps expired entries. Callers run
  `check/2` in their own process, so checks never queue behind each other.
  Each check inserts a row for the request, counts the rows in the window up to
  and including its own, and deletes its row when the count is over the limit.
  Concurrent checks cannot both slip under the limit.

  ## Starting it

  Add it to the application's supervision tree before anything that calls it:

      def start(_type, _args) do
        children = [
          MyApp.Repo,
          {MyApp.RateLimiter, limits_file: Application.fetch_env!(:my_app, :rate_limits_file)},
          MyAppWeb.Endpoint
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
      end

  with, in `config/runtime.exs`:

      config :my_app, rate_limits_file: System.get_env("RATE_LIMITS_FILE", "priv/rate_limits.json")

  A missing or malformed file stops the application from booting.

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.generate(conn.assigns.current_user, params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.SyncContacts do
        use Oban.Worker

        alias MyApp.RateLimiter

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case RateLimiter.check(user_id) do
            :ok -> MyApp.Contacts.sync(user_id)
            {:error, :rate_limited} -> {:snooze, 30}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: term()

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_file` - path of the JSON file with the limits. Required.
    * `:name` - the name of the process and of its ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_file, name: __MODULE__])
    limits_file = Keyword.fetch!(opts, :limits_file)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, limits_file}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit for the last minute.
  Returns `{:error, :rate_limited}` when they are not; the rejected request
  is not counted against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    limit = limit_for(name, user_id)
    request = {System.monotonic_time(:millisecond), System.unique_integer([:monotonic])}
    :ets.insert(name, {request_key(user_id, request)})

    if count_through(name, user_id, request) <= limit do
      :ok
    else
      :ets.delete(name, request_key(user_id, request))
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, limits_file}) do
    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    load_limits!(name, limits_file)
    schedule_sweep()

    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    sweep(name)
    schedule_sweep()

    {:noreply, name}
  end

  defp request_key(user_id, {timestamp, sequence}), do: {user_id, timestamp, sequence}

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, to_string(user_id)}) do
      [{_key, limit}] -> limit
      [] -> default_limit(name)
    end
  end

  defp default_limit(name) do
    [{:default, limit}] = :ets.lookup(name, :default)
    limit
  end

  # Counts this user's requests in the window up to and including `request`.
  # Requests that arrived after it do not count against it, so of two
  # concurrent requests the later one is the one rejected.
  defp count_through(name, user_id, {timestamp, _sequence} = request) do
    match_spec = [
      {
        {{user_id, :"$1", :"$2"}},
        [
          {:>, :"$1", timestamp - @window_ms},
          {:"=<", {{:"$1", :"$2"}}, {request}}
        ],
        [true]
      }
    ]

    :ets.select_count(name, match_spec)
  end

  defp sweep(name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}]

    :ets.select_delete(name, match_spec)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_limits!(name, limits_file) do
    %{"default" => default, "users" => users} =
      limits_file
      |> File.read!()
      |> JSON.decode!()

    :ets.insert(name, {:default, validate_limit!(default)})

    for {user_id, limit} <- users do
      :ets.insert(name, {{:limit, user_id}, validate_limit!(limit)})
    end

    :ok
  end

  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: limit

  defp validate_limit!(limit) do
    raise ArgumentError, "a rate limit must be a positive integer, got: #{inspect(limit)}"
  end
end
