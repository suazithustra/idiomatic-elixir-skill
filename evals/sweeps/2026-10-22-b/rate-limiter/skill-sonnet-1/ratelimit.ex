defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  Limits come from a trusted Elixir script read once when the limiter starts. It
  evaluates to a map from user id to limit. The `:default` key is required and
  applies to users without their own entry:

      %{
        "user-1" => 120,
        "user-2" => 10,
        default: 60
      }

  The path is the `:config_path` option, or else the `:config_path` key of the
  `:my_app, MyApp.RateLimiter` application environment, read at startup.

  ## Starting it

  Add it to the supervision tree before anything that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: "priv/rate_limits.terms"},
        {Task.Supervisor, name: MyApp.TaskSupervisor},
        MyAppWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.generate(params)
              json(conn, report)

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
              |> send_resp(429, "Too many requests")
          end
        end
      end

  Background jobs call `check/1` the same way (see `MyApp.RateLimiter.ExampleJob`).

  ## How it works

  The process only owns an ETS table and sweeps old entries. `check/2` runs in the
  caller's process, so callers never queue behind one another. Each check inserts a
  row for the request first, then counts the user's rows inside the last minute, and
  removes its own row if the count is over the limit. Concurrent checks can
  therefore never let more than the limit through; at the boundary, two simultaneous
  requests may both be refused where one would have fit.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @typedoc "Any term identifying a user, matching the ids in the config file."
  @type user_id :: term()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path to the limits file. Required unless set in the
      application environment.
    * `:name` - name of the process and its ETS table. Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is under their limit, or
  `{:error, {:rate_limited, retry_after_ms}}` when the request was refused.
  Refused requests do not count against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    row_key = {user_id, now, :erlang.unique_integer([:monotonic])}
    :ets.insert(name, {row_key})

    if count_since(name, user_id, now - @window_ms) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, {:rate_limited, retry_after(name, user_id, now)}}
    end
  end

  @doc """
  Returns the limit that applies to `user_id`.
  """
  @spec limit_for(atom(), user_id()) :: pos_integer()
  def limit_for(name \\ __MODULE__, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, {:limit, :default}, 2)
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, path} <- config_path(opts),
         {:ok, limits} <- read_limits(path) do
      :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
      :ets.insert(name, Enum.map(limits, fn {user_id, limit} -> {{:limit, user_id}, limit} end))
      schedule_sweep()
      {:ok, name}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp config_path(opts) do
    case Keyword.get(opts, :config_path) || app_env_path() do
      nil -> {:error, :missing_config_path}
      path -> {:ok, path}
    end
  end

  defp app_env_path do
    :my_app
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:config_path)
  end

  defp read_limits(path) do
    if File.regular?(path) do
      {limits, _binding} = Code.eval_file(path)
      validate_limits(limits)
    else
      {:error, {:unreadable_config, path}}
    end
  end

  defp validate_limits(%{default: _default} = limits) do
    if Enum.all?(limits, fn {_user_id, limit} -> is_integer(limit) and limit > 0 end) do
      {:ok, limits}
    else
      {:error, :invalid_limit_entry}
    end
  end

  defp validate_limits(limits) when is_map(limits), do: {:error, :missing_default_limit}

  defp count_since(name, user_id, cutoff) do
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp retry_after(name, user_id, now) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]

    case :ets.select(name, match_spec, 1) do
      {[oldest], _continuation} -> max(oldest + @window_ms - now, 0)
      :"$end_of_table" -> 0
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end

defmodule MyApp.RateLimiter.ExampleJob do
  @moduledoc """
  Example of a background job that checks the limiter before doing work.
  """

  @doc """
  Runs `work_fun` for `user_id` unless the user is over their limit.

  Returns `{:snooze, seconds}` when limited, so a job runner can retry later.
  """
  @spec perform(term(), (-> result)) :: {:ok, result} | {:snooze, pos_integer()}
        when result: term()
  def perform(user_id, work_fun) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> {:ok, work_fun.()}
      {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
    end
  end
end
