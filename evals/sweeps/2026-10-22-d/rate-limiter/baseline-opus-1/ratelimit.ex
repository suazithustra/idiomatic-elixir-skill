defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter with a rolling one-minute window.

  Each user may make at most N requests in any 60-second span. N comes from a
  JSON file read once when the limiter starts:

      {
        "default": 60,
        "users": {
          "42": 600,
          "alice@example.com": 10
        }
      }

  Users not listed get `"default"`. User ids are compared as strings, so
  `42` and `"42"` refer to the same user.

  The limiter keeps an exact log of request timestamps per user (a sliding
  log, not fixed buckets), so a user can never exceed N requests in any
  60-second span. Checks go through a single process, which makes
  check-and-record atomic without locks.

  ## Starting

  Add it to your application's supervision tree:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        ...
      ]

  ## Usage

      case MyApp.RateLimiter.check(user_id) do
        :ok -> do_work()
        {:error, :rate_limited, retry_after_ms} -> ...
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer() | atom()

  ## Client API

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the JSON limits file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within the user's limit.

  Returns `:ok` when the request is allowed (and counted), or
  `{:error, :rate_limited, retry_after_ms}` when it is not, where
  `retry_after_ms` is how long until the oldest request leaves the window.
  Rejected requests are not counted.
  """
  @spec check(user_id(), GenServer.server()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @doc "Returns the configured per-minute limit for `user_id`."
  @spec limit_for(user_id(), GenServer.server()) :: pos_integer()
  def limit_for(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:limit_for, to_string(user_id)})
  end

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)

    case load_limits(path) do
      {:ok, default, limits} ->
        schedule_sweep()
        {:ok, %{default: default, limits: limits, log: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, path, reason}}
    end
  end

  @impl true
  def handle_call({:check, user}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits, user, state.default)
    {count, timestamps} = state.log |> Map.get(user, {0, :queue.new()}) |> prune(now)

    if count < limit do
      entry = {count + 1, :queue.in(now, timestamps)}
      {:reply, :ok, put_in(state.log[user], entry)}
    else
      {:value, oldest} = :queue.peek(timestamps)
      retry_after = oldest + @window_ms - now
      {:reply, {:error, :rate_limited, retry_after}, put_in(state.log[user], {count, timestamps})}
    end
  end

  def handle_call({:limit_for, user}, _from, state) do
    {:reply, Map.get(state.limits, user, state.default), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    log =
      for {user, entry} <- state.log,
          {count, _} = pruned = prune(entry, now),
          count > 0,
          into: %{},
          do: {user, pruned}

    schedule_sweep()
    {:noreply, %{state | log: log}}
  end

  # Drops timestamps that have left the window. The count is tracked alongside
  # the queue because :queue.len/1 is O(n).
  defp prune({count, timestamps} = entry, now) do
    cutoff = now - @window_ms

    case :queue.peek(timestamps) do
      {:value, ts} when ts <= cutoff -> prune({count - 1, :queue.drop(timestamps)}, now)
      _ -> entry
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_limits(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"default" => default} = config} <- JSON.decode(body),
         true <- valid_limit?(default) || {:error, {:bad_default, default}},
         users = Map.get(config, "users", %{}),
         true <- is_map(users) || {:error, :users_not_an_object},
         [] <- for({user, n} <- users, not valid_limit?(n), do: user) do
      {:ok, default, users}
    else
      {:ok, _no_default} -> {:error, :missing_default}
      bad_users when is_list(bad_users) -> {:error, {:bad_user_limits, bad_users}}
      {:error, _} = error -> error
    end
  end

  defp valid_limit?(n), do: is_integer(n) and n >= 0
end

defmodule MyApp.Application do
  # Example of starting the limiter in the application's supervision tree.
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      # MyApp.Repo, MyAppWeb.Endpoint, Oban, ...
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# ---------------------------------------------------------------------------
# Example callers (require Phoenix / Oban; not compiled here).
# ---------------------------------------------------------------------------

# A plug that any controller or pipeline can use:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(%{assigns: %{current_user: %{id: user_id}}} = conn, _opts) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok ->
#             conn
#
#           {:error, :rate_limited, retry_after_ms} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
#             |> send_resp(429, "Too Many Requests")
#             |> halt()
#         end
#       end
#
#       def call(conn, _opts), do: conn
#     end
#
#     # In a controller:
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       plug MyAppWeb.Plugs.RateLimit when action in [:create]
#
#       def create(conn, params) do
#         ...
#       end
#     end
#
# A background job, snoozing until the user has capacity again:
#
#     defmodule MyApp.Workers.SyncAccount do
#       use Oban.Worker, queue: :default
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok -> MyApp.Accounts.sync(user_id)
#           {:error, :rate_limited, retry_after_ms} -> {:snooze, div(retry_after_ms + 999, 1000)}
#         end
#       end
#     end
