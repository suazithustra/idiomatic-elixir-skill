defmodule MyApp.RateLimiter.LimitExceededError do
  @moduledoc """
  The reason `MyApp.RateLimiter.check/2` returns when it refuses a request.

  `:retry_after_seconds` is the time until the user's oldest counted request
  leaves the window, rounded up.
  """

  @enforce_keys [:user_id, :limit, :retry_after_seconds]
  defexception [:user_id, :limit, :retry_after_seconds]

  @type t :: %__MODULE__{
          user_id: String.t(),
          limit: non_neg_integer(),
          retry_after_seconds: pos_integer()
        }

  @impl true
  def message(%__MODULE__{} = error) do
    "user #{error.user_id} is over the limit of #{error.limit} requests, " <>
      "retry in #{error.retry_after_seconds} s"
  end
end

defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a configured number of requests per rolling minute.

  `check/2` runs in the calling process against an ETS table, so controllers and
  jobs do not queue behind one process. The GenServer only owns the table and
  removes expired rows.

  ## Configuration file

  The limits come from a JSON file read once, when the limiter starts. `"default"`
  applies to every user not listed under `"users"`, and both keys are required.
  User IDs are compared as strings, so `42` and `"42"` are the same user. A limit
  of `0` blocks the user.

      {
        "default": 60,
        "users": {
          "42": 600,
          "7f3c9a54-8e0e-4f2a-9d6b-1c2e5a7b3d10": 5
        }
      }

  A missing or invalid file stops the limiter from starting, which stops the
  application at boot instead of letting it run without limits.

  Counts are held in memory on one node. Each node counts separately, so a cluster
  of three allows up to three times the limit, and restarting the limiter clears
  the counts.

  ## Starting

  Add the limiter to the children in `MyApp.Application.start/2`, before anything
  that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)

  ## Calling from a controller

  A plug keeps the check and the 429 (Too Many Requests) response in one place. It
  must run after the plug that assigns `:current_user`.

      defmodule MyAppWeb.Plugs.RateLimit do
        @behaviour Plug

        import Plug.Conn

        alias MyApp.RateLimiter
        alias MyApp.RateLimiter.LimitExceededError

        @impl true
        def init(opts), do: opts

        @impl true
        def call(conn, _opts) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, %LimitExceededError{} = error} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(error.retry_after_seconds))
              |> send_resp(:too_many_requests, "Too many requests")
              |> halt()
          end
        end
      end

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        plug MyAppWeb.Plugs.RateLimit

        def create(conn, %{"report" => report_params}) do
          # ...
        end
      end

  ## Calling from a background job

  A job that is refused waits for a slot instead of failing:

      defmodule MyApp.Workers.ExportWorker do
        use Oban.Worker, queue: :exports

        alias MyApp.RateLimiter
        alias MyApp.RateLimiter.LimitExceededError

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case RateLimiter.check(user_id) do
            :ok ->
              MyApp.Exports.run(user_id)

            {:error, %LimitExceededError{} = error} ->
              {:snooze, error.retry_after_seconds}
          end
        end
      end
  """

  use GenServer

  alias MyApp.RateLimiter.LimitExceededError

  @window_ms :timer.minutes(1)

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter and reads the limits from the configuration file.

  ## Options

    * `:config_path` - path of the JSON file holding the limits. Required.
    * `:name` - atom naming both the process and its ETS table. Defaults to
      `MyApp.RateLimiter`.
    * `:window_ms` - length of the rolling window. Defaults to one minute. Tests
      can set a short window instead of waiting a minute.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__, window_ms: @window_ms])
    GenServer.start_link(__MODULE__, Map.new(opts), name: opts[:name])
  end

  @doc """
  Counts a request by `user_id` if the user is under their limit.

  Returns `:ok` when the work may go ahead. The request now counts against the
  limit, so call this once per unit of work, just before doing it.

  Returns `{:error, %LimitExceededError{}}` when the user has reached their limit.
  A refused request does not count. Requests from one user racing for that user's
  last slots can all be refused, but the limit is never exceeded.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, LimitExceededError.t()}
  def check(name \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    user_key = to_string(user_id)
    config = :persistent_term.get({__MODULE__, name})
    limit = Map.get(config.users, user_key, config.default)
    now = System.monotonic_time(:millisecond)
    hit = {user_key, now, System.unique_integer()}

    # Insert before counting. Whichever request inserts last sees every earlier one,
    # so concurrent requests cannot all find room, as they could by counting first.
    :ets.insert(name, {hit})

    if count_hits(name, user_key, now - config.window_ms) <= limit do
      :ok
    else
      refuse(name, hit, limit, config.window_ms)
    end
  end

  @impl true
  def init(%{config_path: config_path, name: name, window_ms: window_ms})
      when is_binary(config_path) and is_atom(name) and is_integer(window_ms) and window_ms > 0 do
    # Read here, not in handle_continue/2: callers need the limits as soon as
    # start_link/1 returns, and a bad file has to fail the start.
    case load_limits(config_path) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, Map.put(limits, :window_ms, window_ms))
        :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
        schedule_sweep(window_ms)
        {:ok, %{name: name, window_ms: window_ms}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, config_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    window_start = System.monotonic_time(:millisecond) - state.window_ms
    :ets.select_delete(state.name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", window_start}], [true]}])
    schedule_sweep(state.window_ms)
    {:noreply, state}
  end

  defp schedule_sweep(window_ms), do: Process.send_after(self(), :sweep, window_ms)

  defp refuse(name, {user_key, now, _unique} = hit, limit, window_ms) do
    # Read before deleting: this hit is in the window, so the select always finds a row.
    retry_after_ms = oldest_hit(name, user_key, now - window_ms) + window_ms - now
    :ets.delete(name, hit)

    error = %LimitExceededError{
      user_id: user_key,
      limit: limit,
      retry_after_seconds: ceil(retry_after_ms / 1000)
    }

    {:error, error}
  end

  defp count_hits(name, user_key, window_start) do
    :ets.select_count(name, hit_spec(user_key, window_start, true))
  end

  defp oldest_hit(name, user_key, window_start) do
    {[oldest], _continuation} = :ets.select(name, hit_spec(user_key, window_start, :"$1"), 1)
    oldest
  end

  # Rows are keyed {user_key, time, unique}. In an ordered_set, a key that starts with
  # a bound user_key limits the scan to that user's rows, returned oldest first.
  defp hit_spec(user_key, window_start, result) do
    [{{{user_key, :"$1", :_}}, [{:>, :"$1", window_start}], [result]}]
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, config} <- JSON.decode(contents) do
      parse_limits(config)
    end
  end

  defp parse_limits(%{"default" => default, "users" => users}) when is_map(users) do
    limits = [{"default", default} | Map.to_list(users)]

    case Enum.find(limits, fn {_key, limit} -> not valid_limit?(limit) end) do
      nil -> {:ok, %{default: default, users: users}}
      {key, limit} -> {:error, {:invalid_limit, key, limit}}
    end
  end

  defp parse_limits(_config), do: {:error, :invalid_format}

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end
