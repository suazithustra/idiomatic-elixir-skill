defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests per rolling window.

  N comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"42": 600, "43": 10}}

  Users not listed under `"users"` get the `"default"` limit. User IDs are
  compared as strings, so `42` and `"42"` are the same user.

  Every request is recorded as one row in a public ETS (Erlang Term Storage)
  table, and callers read and write the table from their own processes, so no
  call waits on the owning process. The owning process creates the table and
  periodically deletes rows older than the window.

  A request is inserted first and counted afterwards, and the row is deleted
  when the count is over the limit. That keeps concurrent callers from both
  seeing room for one more request. A rejected request can briefly count
  against other concurrent requests from the same user.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and anything that runs jobs:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: "priv/rate_limits.json"},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

  If `:config_path` is not given, it is read from
  `config :my_app, MyApp.RateLimiter, config_path: "..."` when the limiter
  starts, so `config/runtime.exs` can set it.

  ## Calling it from a controller

      defmodule MyAppWeb.Plugs.RateLimit do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

      # in a controller
      plug MyAppWeb.Plugs.RateLimit when action in [:create, :update]

  See `MyApp.Workers.ExportReport` below for a background job.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  defmodule Limits do
    @moduledoc false
    @enforce_keys [:default, :users, :window_ms]
    defstruct [:default, :users, :window_ms]

    @type t :: %__MODULE__{
            default: pos_integer(),
            users: %{String.t() => pos_integer()},
            window_ms: pos_integer()
          }
  end

  @type user_id :: String.t() | integer()

  ## Client

  @doc """
  Starts the limiter and its table.

  ## Options

    * `:config_path` - path to the JSON limits file. Defaults to the
      `:config_path` entry of `config :my_app, MyApp.RateLimiter`.
    * `:name` - the name of the process and of its ETS table, which must be an
      atom. Defaults to `MyApp.RateLimiter`.
    * `:window_ms` - length of the rolling window. Defaults to one minute.
    * `:sweep_interval_ms` - how often expired rows are deleted. Defaults to
      30 seconds.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, :name, :window_ms, :sweep_interval_ms])
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit, or
  `{:error, {:rate_limited, retry_after_ms}}` when they are not. A rejected
  request is not recorded.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    %Limits{window_ms: window_ms} = limits = :persistent_term.get({__MODULE__, name})
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    row_key = {user, now, :erlang.unique_integer([:monotonic])}
    :ets.insert(name, {row_key})

    if count_since(name, user, cutoff) <= limit_for(limits, user) do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, {:rate_limited, retry_after(name, user, cutoff, window_ms, now)}}
    end
  end

  @doc """
  Returns the limit that applies to `user_id`.
  """
  @spec limit(atom(), user_id()) :: pos_integer()
  def limit(name \\ __MODULE__, user_id) do
    limit_for(:persistent_term.get({__MODULE__, name}), to_string(user_id))
  end

  defp limit_for(%Limits{users: users, default: default}, user) do
    Map.get(users, user, default)
  end

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp retry_after(name, user, cutoff, window_ms, now) do
    spec = [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [:"$1"]}]

    case :ets.select(name, spec, 1) do
      {[oldest], _continuation} -> max(oldest + window_ms - now, 0)
      :"$end_of_table" -> 0
    end
  end

  ## Server

  @impl true
  def init({name, opts}) do
    with {:ok, path} <- config_path(opts),
         {:ok, limits} <- load_limits(path, Keyword.get(opts, :window_ms, @window_ms)) do
      :ets.new(name, [
        :named_table,
        :public,
        :ordered_set,
        read_concurrency: true,
        write_concurrency: true
      ])

      :persistent_term.put({__MODULE__, name}, limits)
      sweep_interval_ms = Keyword.get(opts, :sweep_interval_ms, @sweep_interval_ms)
      schedule_sweep(sweep_interval_ms)
      {:ok, %{name: name, window_ms: limits.window_ms, sweep_interval_ms: sweep_interval_ms}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - state.window_ms
    :ets.select_delete(state.name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  defp schedule_sweep(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  ## Config loading

  defp config_path(opts) do
    case Keyword.fetch(opts, :config_path) do
      {:ok, path} -> {:ok, path}
      :error -> app_config_path()
    end
  end

  defp app_config_path do
    case Application.get_env(:my_app, __MODULE__, [])[:config_path] do
      nil -> {:error, :missing_config_path}
      path -> {:ok, path}
    end
  end

  defp load_limits(path, window_ms) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents),
         {:ok, default} <- fetch_limit(decoded, "default"),
         {:ok, users} <- parse_users(decoded) do
      {:ok, %Limits{default: default, users: users, window_ms: window_ms}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:config_unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, :config_not_an_object}
      {:error, reason} -> {:error, {:config_invalid_json, reason}}
    end
  end

  defp fetch_limit(%{"default" => limit}, "default") when is_integer(limit) and limit > 0,
    do: {:ok, limit}

  defp fetch_limit(_decoded, "default"), do: {:error, {:invalid_limit, "default"}}

  defp parse_users(%{"users" => users}) when is_map(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn
      {user, limit}, {:ok, acc} when is_integer(limit) and limit > 0 ->
        {:cont, {:ok, Map.put(acc, user, limit)}}

      {user, _limit}, {:ok, _acc} ->
        {:halt, {:error, {:invalid_limit, user}}}
    end)
  end

  defp parse_users(%{"users" => _other}), do: {:error, {:invalid_limit, "users"}}
  defp parse_users(%{}), do: {:ok, %{}}
end

defmodule MyApp.Workers.ExportReport do
  @moduledoc """
  Example caller: a background job that checks the limiter before doing work.

  With Oban, `use Oban.Worker` and `perform/1` take the place of the plain
  function below; returning `{:snooze, seconds}` reschedules the job.
  """

  @spec perform(%{user_id: MyApp.RateLimiter.user_id()}) :: :ok | {:snooze, pos_integer()}
  def perform(%{user_id: user_id}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok ->
        build_report(user_id)

      {:error, {:rate_limited, retry_after_ms}} ->
        {:snooze, div(retry_after_ms, 1000) + 1}
    end
  end

  defp build_report(_user_id), do: :ok
end
