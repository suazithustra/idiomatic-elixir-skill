defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any
  rolling minute.

  N comes from a configuration file that is read once, when the limiter
  starts. The file is an Elixir script that returns a map with a default
  limit and optional per-user limits:

      # config/rate_limits.exs
      %{
        default: 60,
        users: %{
          "user-17" => 300,
          "user-42" => 10
        }
      }

  A user missing from `:users` gets `:default`. User IDs are matched exactly
  as callers pass them, so use the same type (string or integer) in the file
  and in `check/2`.

  The limiter process only owns the ETS (Erlang Term Storage) table, loads
  the file and sweeps old entries. `check/2` runs in the caller's process, so
  controllers and background jobs do not queue behind one process.

  ## Starting it

  Add it to the supervision tree before the endpoint and before anything
  that calls it, such as the job runner:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

      # config/runtime.exs
      config :my_app, rate_limits_path: "config/rate_limits.exs"

  If the file is missing or malformed, the limiter fails to start and so
  does the application.

  ## Options

    * `:config_path` - path of the limits file. Required.
    * `:name` - registered name, also the name of the ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
    * `:window` - length of the rolling window in milliseconds. Defaults to
      one minute.
    * `:sweep_interval` - how often entries older than the window are
      deleted, in milliseconds. Defaults to one minute.

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter
        alias MyApp.Reports

        action_fallback MyAppWeb.FallbackController

        def create(conn, params) do
          user = conn.assigns.current_user

          with :ok <- RateLimiter.check(user.id),
               {:ok, report} <- Reports.create_report(user, params) do
            conn
            |> put_status(:created)
            |> render(:show, report: report)
          end
        end
      end

      defmodule MyAppWeb.FallbackController do
        use MyAppWeb, :controller

        def call(conn, {:error, {:rate_limited, retry_after}}) do
          seconds = div(retry_after + 999, 1000)

          conn
          |> put_resp_header("retry-after", Integer.to_string(seconds))
          |> put_status(:too_many_requests)
          |> json(%{error: "rate limit exceeded"})
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.SyncAccount do
        use Oban.Worker

        alias MyApp.RateLimiter

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          with :ok <- RateLimiter.check(user_id) do
            MyApp.Accounts.sync(user_id)
          end
        end
      end

  A job that gets `{:error, {:rate_limited, retry_after}}` can return
  `{:snooze, seconds}` instead, so the queue retries it after the wait.
  """

  use GenServer

  @default_window :timer.minutes(1)
  @default_sweep_interval :timer.minutes(1)

  @type user_id :: term()
  @type retry_after :: pos_integer()

  @doc """
  Starts the limiter. See the module documentation for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, :name, :window, :sweep_interval])
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc """
  Records one request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit. Otherwise the request
  is not counted and the result is `{:error, {:rate_limited, retry_after}}`,
  where `retry_after` is the number of milliseconds until the user's oldest
  counted request leaves the window.

  Safe to call from many processes at once: the request is recorded first and
  withdrawn if it is over the limit, so concurrent calls never let a user
  exceed the limit. Under contention a call may be refused because another
  call that is itself about to be refused was counted for an instant.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, retry_after()}}
  def check(name \\ __MODULE__, user_id) do
    now = now()
    window = :ets.lookup_element(name, :window, 2)
    entry = {:request, user_id, now, :erlang.unique_integer([:monotonic])}

    :ets.insert(name, {entry})
    timestamps = request_times(name, user_id, now - window)

    if length(timestamps) <= limit(name, user_id) do
      :ok
    else
      :ets.delete(name, entry)
      {:error, {:rate_limited, Enum.min(timestamps) + window - now}}
    end
  end

  @impl true
  def init({name, opts}) do
    config_path = Keyword.fetch!(opts, :config_path)

    with {:ok, config} <- load_config(config_path) do
      window = Keyword.get(opts, :window, @default_window)
      sweep_interval = Keyword.get(opts, :sweep_interval, @default_sweep_interval)

      :ets.new(name, [
        :named_table,
        :public,
        :ordered_set,
        read_concurrency: true,
        write_concurrency: true
      ])

      store_config(name, config, window)
      Process.send_after(self(), :sweep, sweep_interval)

      {:ok, %{table: name, window: window, sweep_interval: sweep_interval}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    delete_expired(state.table, now() - state.window)
    Process.send_after(self(), :sweep, state.sweep_interval)
    {:noreply, state}
  end

  defp load_config(path) do
    with {:ok, source} <- read_file(path),
         {:ok, config} <- eval_config(source, path) do
      validate_config(config)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:stop, {:config_unreadable, path, reason}}
    end
  end

  defp eval_config(source, path) do
    {config, _bindings} = Code.eval_string(source, [], file: path)
    {:ok, config}
  end

  defp validate_config(%{default: default, users: users} = config)
       when is_integer(default) and default >= 0 and is_map(users) do
    if Enum.all?(users, fn {_user_id, limit} -> is_integer(limit) and limit >= 0 end) do
      {:ok, config}
    else
      {:stop, {:invalid_config, :user_limits}}
    end
  end

  defp validate_config(%{default: default} = config)
       when is_integer(default) and default >= 0 do
    validate_config(Map.put(config, :users, %{}))
  end

  defp validate_config(_config), do: {:stop, {:invalid_config, :default}}

  defp store_config(table, config, window) do
    user_limits = Enum.map(config.users, fn {user_id, limit} -> {{:limit, user_id}, limit} end)

    :ets.insert(table, [{:window, window}, {:default_limit, config.default} | user_limits])
  end

  defp limit(table, user_id) do
    case :ets.lookup(table, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(table, :default_limit, 2)
    end
  end

  defp request_times(table, user_id, cutoff) do
    match_spec = [{{{:request, user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [:"$1"]}]
    :ets.select(table, match_spec)
  end

  defp delete_expired(table, cutoff) do
    match_spec = [{{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(table, match_spec)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
