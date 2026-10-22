defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter over a rolling one-minute window.

  Each user may make at most N requests in any 60-second span. N comes from a
  JSON file read once when the limiter starts:

      {
        "default_limit": 60,
        "users": {
          "42": 600,
          "1337": 5
        }
      }

  Users not listed under `"users"` get `"default_limit"`.

  The limiter is a supervised process that owns an ETS table. Callers check
  the limit in their own process, so controllers and jobs never wait on a
  single mailbox. The process only creates the table and sweeps expired rows.

  ## Starting

  Add it to the application's supervision tree, before the endpoint and any
  job runner that calls it:

      children = [
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_config)},
        MyAppWeb.Endpoint
      ]

  ## Calling

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, :rate_limited} -> back_off()
      end
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.seconds(10)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and loads the per-user limits from `:config_path`.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - the registered name, which is also the ETS table name.
      Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records one request for `user_id` and returns `:ok` if it is within the
  user's limit for the last minute, or `{:error, :rate_limited}` if it is not.

  A rejected request does not count against the limit.
  """
  @spec check(GenServer.name(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) when is_binary(user_id) or is_integer(user_id) do
    key = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    request = {{key, now, System.unique_integer()}}

    # Insert first, then count: each step is atomic on its own, so concurrent
    # requests cannot both see a stale count and both slip under the limit.
    :ets.insert(name, request)

    if requests_in_window(name, key, now) <= limit_for(name, key) do
      :ok
    else
      :ets.delete_object(name, request)
      {:error, :rate_limited}
    end
  end

  @doc """
  Returns the per-minute limit that applies to `user_id`.
  """
  @spec limit(GenServer.name(), user_id()) :: pos_integer()
  def limit(name \\ __MODULE__, user_id) when is_binary(user_id) or is_integer(user_id) do
    limit_for(name, to_string(user_id))
  end

  defp requests_in_window(name, key, now) do
    cutoff = now - @window
    in_window = [{{{key, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, in_window)
  end

  defp limit_for(name, key) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, key, limits.default_limit)
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, limits)
        create_table(name)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window
    expired = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, expired)
    schedule_sweep()
    {:noreply, name}
  end

  defp create_table(name) do
    # An ordered_set keyed by {user_id, timestamp, unique} lets select_count
    # scan only the rows of one user instead of the whole table.
    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp load_limits(config_path) do
    with {:ok, contents} <- read_config(config_path),
         {:ok, config} <- decode_config(contents),
         {:ok, default_limit} <- parse_default_limit(config),
         {:ok, users} <- parse_user_limits(config) do
      {:ok, %{default_limit: default_limit, users: users}}
    end
  end

  defp read_config(config_path) do
    case File.read(config_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, config_path, reason}}
    end
  end

  defp decode_config(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = config} -> {:ok, config}
      {:ok, other} -> {:error, {:invalid_config, other}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_default_limit(%{"default_limit" => limit}) when is_integer(limit) and limit > 0 do
    {:ok, limit}
  end

  defp parse_default_limit(%{"default_limit" => _limit}) do
    {:error, {:invalid_field, "default_limit"}}
  end

  defp parse_default_limit(%{}), do: {:error, {:missing_field, "default_limit"}}

  defp parse_user_limits(%{"users" => %{} = users}) do
    Enum.reduce_while(users, {:ok, %{}}, fn
      {user_id, limit}, {:ok, acc} when is_integer(limit) and limit > 0 ->
        {:cont, {:ok, Map.put(acc, user_id, limit)}}

      {user_id, _limit}, _acc ->
        {:halt, {:error, {:invalid_user_limit, user_id}}}
    end)
  end

  defp parse_user_limits(%{"users" => _users}), do: {:error, {:invalid_field, "users"}}
  defp parse_user_limits(%{}), do: {:ok, %{}}
end

defmodule MyApp.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    rate_limiter_options = [config_path: Application.fetch_env!(:my_app, :rate_limit_config)]

    children = [
      MyApp.Repo,
      {MyApp.RateLimiter, rate_limiter_options},
      {Oban, Application.fetch_env!(:my_app, Oban)},
      MyAppWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end

# config/runtime.exs:
#
#     config :my_app, :rate_limit_config, System.fetch_env!("RATE_LIMIT_CONFIG")

defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Rejects the request with 429 when the signed-in user is over their limit.

  Add it to a pipeline after authentication, or to a single controller with
  `plug MyAppWeb.Plugs.RateLimit`.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
      :ok ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, "Too Many Requests")
        |> halt()
    end
  end
end

defmodule MyApp.Workers.ExportReport do
  @moduledoc false

  use Oban.Worker, queue: :reports

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "report_id" => report_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> MyApp.Reports.export(user_id, report_id)
      {:error, :rate_limited} -> {:snooze, 60}
    end
  end
end
