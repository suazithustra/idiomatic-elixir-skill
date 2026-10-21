defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any 60 second window. N comes from a
  JSON file read once when the limiter starts:

  ```json
  {"default": 60, "users": {"42": 600, "17": 10}}
  ```

  Users not listed under `"users"` get `"default"`. User IDs are compared as strings.

  Callers run `check/2` in their own process. The GenServer only owns the ETS
  (Erlang Term Storage) tables and removes expired rows, so it is not a
  bottleneck. Each request is stored as one row, inserted before the count is
  taken, so concurrent callers cannot read the same old count and both pass. If
  several callers hit the limit at the same instant, all of them may be refused;
  the limiter never lets more than N through.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint and
  before anything that runs jobs:

  ```elixir
  children = [
    MyApp.Repo,
    {MyApp.RateLimiter, limits_path: Application.fetch_env!(:my_app, :rate_limits_path)},
    {Oban, Application.fetch_env!(:my_app, Oban)},
    MyAppWeb.Endpoint
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  ```

  ## Calling it from a controller

  ```elixir
  defmodule MyAppWeb.ReportController do
    use MyAppWeb, :controller

    def create(conn, params) do
      case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
        :ok ->
          {:ok, report} = MyApp.Reports.create(conn.assigns.current_user, params)
          json(conn, report)

        {:error, {:rate_limited, retry_after_ms}} ->
          conn
          |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
          |> send_resp(429, "Too many requests")
      end
    end
  end
  ```

  ## Calling it from a background job

  ```elixir
  defmodule MyApp.Workers.SyncWorker do
    use Oban.Worker

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
      case MyApp.RateLimiter.check(user_id) do
        :ok -> MyApp.Sync.run(user_id)
        {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
      end
    end
  end
  ```
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_path` - path of the JSON limits file. Required. Startup fails if
      the file is missing or malformed.
    * `:name` - name of the process and prefix of its tables. Defaults to
      `#{inspect(__MODULE__)}`.
    * `:sweep_interval` - milliseconds between removals of expired rows.
      Defaults to `#{@sweep_interval_ms}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [:limits_path, name: __MODULE__, sweep_interval: @sweep_interval_ms])

    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Records a request for `user_id` and returns `:ok` if it is within the limit.

  When over the limit, the request is not recorded and the result says how many
  milliseconds until the user's oldest request leaves the window.

  ## Examples

      MyApp.RateLimiter.check(42)
      #=> :ok

      MyApp.RateLimiter.check(42)
      #=> {:error, {:rate_limited, 41_250}}
  """
  @spec check(GenServer.name(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) when is_binary(user_id) or is_integer(user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    row_key = {user, now, :erlang.unique_integer()}

    true = :ets.insert(name, {row_key})

    if count_since(name, user, now - @window_ms) <= limit_for(name, user) do
      :ok
    else
      true = :ets.delete(name, row_key)
      {:error, {:rate_limited, retry_after(name, user, now)}}
    end
  end

  @doc """
  Returns the limit that applies to `user_id`.

  ## Examples

      MyApp.RateLimiter.limit_for(42)
      #=> 600
  """
  @spec limit_for(GenServer.name(), user_id()) :: pos_integer()
  def limit_for(name \\ __MODULE__, user_id) do
    user = to_string(user_id)

    case :ets.lookup(limits_table(name), user) do
      [{^user, limit}] -> limit
      [] -> default_limit(name)
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    case load_limits(Keyword.fetch!(opts, :limits_path)) do
      {:ok, limits} ->
        :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])

        limits_table =
          :ets.new(limits_table(name), [:named_table, :protected, :set, read_concurrency: true])

        :ets.insert(limits_table, Map.to_list(limits))

        interval = Keyword.fetch!(opts, :sweep_interval)
        Process.send_after(self(), :sweep, interval)
        {:ok, %{name: name, sweep_interval: interval}}

      {:error, reason} ->
        {:stop, {:invalid_limits_file, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, %{name: name, sweep_interval: interval} = state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, interval)
    {:noreply, state}
  end

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp retry_after(name, user, now) do
    spec = [{{{user, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]

    case :ets.select(name, spec, 1) do
      {[oldest], _continuation} -> max(oldest + @window_ms - now, 1)
      :"$end_of_table" -> 1
    end
  end

  # The default limit is stored under the atom :default, which cannot collide
  # with a user ID because those are always strings.
  defp default_limit(name), do: :ets.lookup_element(limits_table(name), :default, 2)

  defp limits_table(name), do: :"#{name}_limits"

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) when is_integer(default) and default > 0 do
    case user_limits(Map.get(decoded, "users", %{})) do
      {:ok, users} -> {:ok, Map.put(users, :default, default)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_limits(_decoded), do: {:error, :missing_or_invalid_default}

  defp user_limits(users) when is_map(users) do
    if Enum.all?(users, fn {_user, limit} -> is_integer(limit) and limit > 0 end) do
      {:ok, users}
    else
      {:error, :invalid_user_limit}
    end
  end

  defp user_limits(_users), do: {:error, :invalid_users}
end
