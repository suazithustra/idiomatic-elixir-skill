defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling minute.

  The limits come from a JSON file that is read when the limiter starts:

      {"default": 60, "users": {"42": 300}}

  `default` applies to every user not listed under `users`. User IDs in the
  file are strings; any integer or string ID given to `check/2` is matched
  by its string form.

  Callers run `check/2` in their own process before doing the work. The
  check reads and writes a shared ETS table directly, so it does not wait
  behind a single process. The owning GenServer only creates the table,
  loads the limits, and removes expired entries.

  See the bottom of this file for how to start the limiter and call it.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @doc """
  Starts the limiter and its ETS table.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to `#{__MODULE__}`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, %{name: name, config_path: config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and checks it against the user's limit.

  Returns `:ok` when the request may proceed. Returns `{:error, :rate_limited}`
  when the user has already reached the limit in the past minute. A rejected
  request is not counted.
  """
  def check(name \\ __MODULE__, user_id) do
    user_id = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, make_ref()}

    # Record the request before counting. If the count came first, two
    # concurrent checks could both see the same count and both pass.
    :ets.insert(name, {key})

    if count_recent(name, user_id, now) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(%{name: name, config_path: config_path}) do
    case load_limits(config_path) do
      {:ok, default, limits} ->
        :ets.new(name, [
          :ordered_set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

        # Limit rows and request rows share the table. Their keys differ in
        # shape, so the request counts below never match a limit row.
        limit_rows = for {user_id, limit} <- limits, do: {{user_id, :limit}, limit}
        :ets.insert(name, [{:default, default} | limit_rows])

        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])

    schedule_sweep()
    {:noreply, name}
  end

  defp count_recent(name, user_id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    default = :ets.lookup_element(name, :default, 2)
    :ets.lookup_element(name, {user_id, :limit}, 2, default)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, decoded} <- Jason.decode(contents) do
      parse_limits(decoded)
    end
  end

  defp parse_limits(%{"default" => default, "users" => users}) when is_map(users) do
    with {:ok, default} <- validate_limit(default),
         {:ok, users} <- validate_users(users) do
      {:ok, default, users}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_config}

  defp validate_users(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {user_id, limit}, {:ok, acc} ->
      case validate_limit(limit) do
        {:ok, limit} -> {:cont, {:ok, Map.put(acc, user_id, limit)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_limit(limit) when is_integer(limit) and limit >= 0, do: {:ok, limit}
  defp validate_limit(limit), do: {:error, {:invalid_limit, limit}}
end

# ---------------------------------------------------------------------------
# Starting the limiter
#
# Add it to the application supervisor, after anything the config path needs:
#
#     children = [
#       MyApp.Repo,
#       {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
#       MyAppWeb.Endpoint
#     ]
#
# In config/runtime.exs:
#
#     config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")
#
# ---------------------------------------------------------------------------
# Caller: a controller
#
#     defmodule MyAppWeb.ReportController do
#       use MyAppWeb, :controller
#
#       alias MyApp.RateLimiter
#       alias MyApp.Reports
#
#       def create(conn, params) do
#         user = conn.assigns.current_user
#
#         case RateLimiter.check(user.id) do
#           :ok ->
#             {:ok, report} = Reports.create_report(user, params)
#             conn |> put_status(:created) |> json(%{id: report.id})
#
#           {:error, :rate_limited} ->
#             conn |> put_status(:too_many_requests) |> json(%{error: "rate_limited"})
#         end
#       end
#     end
#
# ---------------------------------------------------------------------------
# Caller: a background job (Oban)
#
#     defmodule MyApp.Workers.ExportWorker do
#       use Oban.Worker, queue: :exports
#
#       alias MyApp.Exports
#       alias MyApp.RateLimiter
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case RateLimiter.check(user_id) do
#           :ok -> Exports.run(user_id)
#           {:error, :rate_limited} -> {:snooze, 60}
#         end
#       end
#     end
