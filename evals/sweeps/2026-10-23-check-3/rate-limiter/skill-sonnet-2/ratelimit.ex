defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any
  rolling 60 seconds.

  N comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"42": 600, "1001": 10}}

  A user not listed under `"users"` gets `"default"`. User IDs are matched
  by their string form, so `42` and `"42"` are the same user.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and
  before anything that calls it (in `MyApp.Application`):

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

  and set the path in `config/runtime.exs`:

      config :my_app, rate_limit_file: System.get_env("RATE_LIMIT_FILE", "priv/rate_limits.json")

  If the file is missing or invalid, the limiter does not start, and so the
  application does not boot.

  ## Calling it

  Any process may call `check/2`. The check runs in the caller's process
  against an ETS (Erlang Term Storage) table, so callers do not queue behind
  one another.

  In a controller, as a plug:

      defmodule MyAppWeb.RateLimitPlug do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, :rate_limited} ->
              conn
              |> put_resp_header("retry-after", "60")
              |> send_resp(429, "rate limit exceeded")
              |> halt()
          end
        end
      end

      # in MyAppWeb.ReportController
      plug MyAppWeb.RateLimitPlug when action in [:create]

  In a background job (Oban):

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

  @window_ms :timer.seconds(60)
  @sweep_interval_ms :timer.minutes(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - registered name, which is also the name of the ETS table.
      Defaults to `#{inspect(__MODULE__)}`.
  """
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  A request that is refused is not counted against the user.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    request_key = {:request, user, now, :erlang.unique_integer([:monotonic])}

    # The request is recorded before it is counted. A read followed by a
    # write would let concurrent callers each see room and all go over the
    # limit. Here two callers at the edge may both be refused, but the limit
    # is never exceeded.
    true = :ets.insert(name, {request_key})

    if requests_in_window(name, user, now) <= limit_for(name, user) do
      :ok
    else
      true = :ets.delete(name, request_key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        table_options = [:named_table, :public, :ordered_set, write_concurrency: true]
        :ets.new(name, table_options)
        true = :ets.insert(name, limit_rows(limits))
        Process.send_after(self(), {:sweep, name}, @sweep_interval_ms)
        {:ok, nil}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, config_path, reason}}
    end
  end

  @impl true
  def handle_info({:sweep, name}, state) do
    sweep(name, System.monotonic_time(:millisecond))
    Process.send_after(self(), {:sweep, name}, @sweep_interval_ms)
    {:noreply, state}
  end

  defp requests_in_window(name, user, now) do
    cutoff = now - @window_ms
    match_spec = [{{{:request, user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  # Without this, the table keeps every request ever made.
  defp sweep(name, now) do
    cutoff = now - @window_ms
    match_spec = [{{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, match_spec)
  end

  defp limit_rows(%{default: default, users: users}) do
    user_rows = Enum.map(users, fn {user, limit} -> {{:limit, user}, limit} end)
    [{:default_limit, default} | user_rows]
  end

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default, "users" => users}) when is_map(users) do
    with {:ok, default} <- parse_limit(default),
         {:ok, users} <- parse_user_limits(users) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_shape}

  defp parse_user_limits(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {user, limit}, {:ok, parsed} ->
      case parse_limit(limit) do
        {:ok, limit} -> {:cont, {:ok, Map.put(parsed, user, limit)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp parse_limit(limit), do: {:error, {:invalid_limit, limit}}
end
