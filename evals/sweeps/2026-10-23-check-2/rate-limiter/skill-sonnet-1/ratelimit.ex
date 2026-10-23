defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N comes from a configuration file that is read once, when the limiter starts.
  Users without their own entry get the default limit.

  Callers run `check/2` in their own process. The request log lives in an ETS
  (Erlang Term Storage) table owned by this module's process, so concurrent
  checks do not queue behind a single process. The process only creates the
  table, loads the limits, and removes expired entries.

  ## Configuration file

  The file holds one Erlang term followed by a period, as read by
  `:file.consult/1`. `default` applies to every user not listed under `users`:

      \#{default => 60, users => \#{<<"alice">> => 600, <<"batch-importer">> => 6000}}.

  User IDs are matched exactly, so use the same type (string or integer) in the
  file and in calls to `check/2`. Erlang syntax writes an Elixir string as
  `<<"alice">>`; a plain `"alice"` would be a charlist and never match. An ID must not be an atom such as `:_` or
  `:"$1"`, which ETS treats as a match variable.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and before
  anything that runs jobs, so it is running when the first request arrives:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.term")},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

  If the file is missing or invalid, the limiter fails to start and so does the
  application, which is what we want: running without limits is worse than not
  running.

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        plug :rate_limit

        def index(conn, _params) do
          render(conn, :index, reports: MyApp.Reports.list_reports(conn.assigns.current_user))
        end

        defp rate_limit(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
              |> halt()
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.ExportWorker do
        use Oban.Worker, queue: :exports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Exports.run(user_id)
            {:error, :rate_limited} -> {:snooze, 30}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path of the limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to
      `#{inspect(__MODULE__)}`. Pass another name to run a separate instance,
      for example in a test.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request for `user_id` and says whether it is within the user's limit.

  Returns `:ok` when the user has made at most their limit of requests in the
  last minute, counting this one. Returns `{:error, :rate_limited}` otherwise;
  a rejected request is not counted against the user.

  Under heavy concurrent load for one user, a request that is about to be
  rejected is briefly visible to the others, so a check made at the same instant
  can be rejected slightly early. The limit is never exceeded.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, System.unique_integer([:monotonic])}

    true = :ets.insert(name, {key})

    if count_since(name, user_id, now - @window_ms) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
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

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, config_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp count_since(name, user_id, cutoff) do
    # With the user ID fixed, an ordered_set walks only that user's rows.
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, user_id, limits.default)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp load_limits(path) do
    with {:ok, term} <- consult(path) do
      parse_limits(term)
    end
  end

  defp consult(path) do
    case :file.consult(path) do
      {:ok, [term]} -> {:ok, term}
      {:ok, terms} -> {:error, {:expected_one_term, length(terms)}}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp parse_limits(%{default: default, users: users}) when is_map(users) do
    if valid_limit?(default) and Enum.all?(users, fn {_user_id, limit} -> valid_limit?(limit) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limit}
    end
  end

  defp parse_limits(_term), do: {:error, :expected_default_and_users}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end
