defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  60-second window.

  N comes from a JSON file read once when the limiter starts:

      {
        "default": 60,
        "users": {
          "42": 600,
          "1337": 0
        }
      }

  `"default"` applies to users not listed under `"users"`. A limit of `0`
  blocks the user entirely. User ids are compared as strings, so callers may
  pass integers or binaries.

  ## Design

  Counts live in a public ETS table keyed by `{user_id, second}`. Callers hit
  ETS directly from their own process, so checks run concurrently and never
  queue behind a single GenServer. The GenServer only owns the tables, loads
  the configuration, and periodically deletes expired buckets.

  A check increments the current one-second bucket first and then sums the
  buckets covering the last minute; if the sum exceeds the limit, the increment
  is undone and the request is refused. Because the increment happens before
  the comparison, concurrent callers can never collectively exceed the limit
  (under heavy contention a request may be refused that would just have fit,
  which is the safe direction to err in).

  The window counts the current second plus the 60 before it, so for any real
  60-second interval the user is guaranteed to have made at most N requests.

  Counters are held in memory on the local node: they reset if the limiter
  restarts, and each node in a cluster limits independently.

  ## Starting

  Add it to your supervision tree, before the endpoint and job processors
  that call it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

  A missing or malformed config file makes startup fail, so the app will not
  boot with limits silently disabled.
  """

  use GenServer

  @counters Module.concat(__MODULE__, Counters)
  @limits Module.concat(__MODULE__, Limits)

  @window_seconds 60
  @sweep_interval :timer.seconds(30)

  @type user_id :: String.t() | integer()

  ## Public API

  @doc "Starts the limiter. Requires the `:config_path` option."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a request for `user_id` if it is within the user's limit.

  Returns `:ok` when the request may proceed, or `{:error, :rate_limited}`
  when the user has already made their maximum number of requests in the
  last minute. A refused request does not count against the limit.
  """
  @spec check(user_id()) :: :ok | {:error, :rate_limited}
  def check(user_id) do
    key = to_string(user_id)
    limit = limit_for(key)
    now = System.monotonic_time(:second)
    bucket = {key, now}

    :ets.update_counter(@counters, bucket, 1, {bucket, 0})

    if window_total(key, now) <= limit do
      :ok
    else
      :ets.update_counter(@counters, bucket, -1)
      {:error, :rate_limited}
    end
  end

  @doc "Returns the configured per-minute limit for `user_id`."
  @spec limit_for(user_id()) :: non_neg_integer()
  def limit_for(user_id) do
    case :ets.lookup(@limits, to_string(user_id)) do
      [{_, limit}] -> limit
      [] -> :ets.lookup_element(@limits, :default, 2)
    end
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    {default, users} = load_config!(path)

    :ets.new(@limits, [:set, :named_table, :protected, read_concurrency: true])
    :ets.insert(@limits, [{:default, default} | Map.to_list(users)])

    :ets.new(@counters, [
      :ordered_set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:second) - @window_seconds
    :ets.select_delete(@counters, [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  ## Internals

  defp window_total(key, now) do
    oldest = now - @window_seconds

    @counters
    |> :ets.select([{{{key, :"$1"}, :"$2"}, [{:>=, :"$1", oldest}], [:"$2"]}])
    |> Enum.sum()
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp load_config!(path) do
    config = path |> File.read!() |> JSON.decode!()

    default =
      case config do
        %{"default" => n} when is_integer(n) and n >= 0 -> n
        _ -> raise ArgumentError, "#{path}: \"default\" must be a non-negative integer"
      end

    users =
      case Map.get(config, "users", %{}) do
        users when is_map(users) ->
          Map.new(users, fn
            {id, n} when is_integer(n) and n >= 0 ->
              {id, n}

            {id, other} ->
              raise ArgumentError,
                    "#{path}: limit for user #{inspect(id)} must be a non-negative integer, " <>
                      "got: #{inspect(other)}"
          end)

        _ ->
          raise ArgumentError, "#{path}: \"users\" must be an object"
      end

    {default, users}
  end
end

# ---------------------------------------------------------------------------
# Example callers (require Phoenix / Oban, so they are not compiled here)
# ---------------------------------------------------------------------------
#
# A plug shared by any controller or pipeline that needs limiting:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(conn, _opts) do
#         user = conn.assigns.current_user
#
#         case MyApp.RateLimiter.check(user.id) do
#           :ok ->
#             conn
#
#           {:error, :rate_limited} ->
#             conn
#             |> put_resp_header("retry-after", "60")
#             |> put_status(:too_many_requests)
#             |> Phoenix.Controller.json(%{error: "rate limit exceeded"})
#             |> halt()
#         end
#       end
#     end
#
# Used from a controller (or a router pipeline):
#
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       plug MyAppWeb.Plugs.RateLimit when action in [:create]
#
#       def create(conn, params) do
#         {:ok, report} = MyApp.Reports.create(conn.assigns.current_user, params)
#         json(conn, report)
#       end
#     end
#
# Or checked inline where only one branch of an action does the costly work:
#
#     def export(conn, params) do
#       with :ok <- MyApp.RateLimiter.check(conn.assigns.current_user.id) do
#         send_download(conn, {:binary, MyApp.Export.build(params)}, filename: "export.csv")
#       else
#         {:error, :rate_limited} -> send_resp(conn, 429, "Too many requests")
#       end
#     end
#
# A background job that defers itself rather than failing when limited:
#
#     defmodule MyApp.Workers.SyncAccount do
#       use Oban.Worker, queue: :sync
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           :ok -> MyApp.Accounts.sync(user_id)
#           {:error, :rate_limited} -> {:snooze, 15}
#         end
#       end
#     end
