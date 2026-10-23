defmodule RateLimit do
  @moduledoc """
  Per-user rate limiter using a rolling one-minute window.

  Each user may make at most N requests in any 60 second span. N comes from a
  JSON file read once, when the limiter starts:

      {
        "default": 60,
        "users": {"42": 600, "7": 10}
      }

  User ids are strings in the file. Callers may pass an id of any type that
  implements `String.Chars` (integers, strings); it is converted to a string
  before the lookup. Users not listed get `"default"`.

  ## Starting it

  Add it to the application's supervision tree, before the endpoint and any
  job runners that call it:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {RateLimit, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

      # config/runtime.exs
      config :my_app, rate_limit_file: System.get_env("RATE_LIMIT_FILE", "priv/rate_limits.json")

  If the file is missing or invalid, the limiter crashes on start and the
  application does not boot.

  ## Calling it

      case RateLimit.check(user.id) do
        {:ok, _remaining} -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> reject(retry_after_ms)
      end

  In a Phoenix controller, as a plug:

      defmodule MyAppWeb.Plugs.RateLimit do
        import Plug.Conn

        def init(opts), do: opts

        def call(%{assigns: %{current_user: user}} = conn, _opts) do
          case RateLimit.check(user.id) do
            {:ok, remaining} ->
              put_resp_header(conn, "x-ratelimit-remaining", Integer.to_string(remaining))

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

      # in a controller
      plug MyAppWeb.Plugs.RateLimit

  In a background job (Oban shown; any worker works the same way):

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case RateLimit.check(user_id) do
          {:ok, _remaining} -> do_work(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end

  ## Notes

  All checks go through one process, which keeps the count exact under
  concurrent callers. State is in memory and per node: with several nodes, each
  node allows N per minute, and a restart resets all counts.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer()

  ## Client

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the JSON limits file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is under its limit.

  Returns `{:ok, remaining}` when the request is allowed, or
  `{:error, {:rate_limited, retry_after_ms}}` when it is not. Rejected requests
  are not counted.
  """
  @spec check(user_id(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @doc "Returns the limit that applies to `user_id`."
  @spec limit(user_id(), GenServer.server()) :: pos_integer()
  def limit(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:limit, to_string(user_id)})
  end

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  ## Config

  @doc false
  def load_config!(path) do
    %{"default" => default} = config = path |> File.read!() |> JSON.decode!()
    users = Map.get(config, "users", %{})

    validate_limit!("default", default)
    Enum.each(users, fn {id, limit} -> validate_limit!(id, limit) end)

    %{default: default, users: users}
  end

  defp validate_limit!(_who, limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(who, limit) do
    raise ArgumentError,
          "rate limit for #{inspect(who)} must be a positive integer, got: #{inspect(limit)}"
  end

  ## Server

  # `hits` maps user id => {count, queue of monotonic timestamps, oldest first}.
  @impl GenServer
  def init(opts) do
    config = opts |> Keyword.fetch!(:config_path) |> load_config!()
    schedule_sweep()
    {:ok, %{config: config, hits: %{}}}
  end

  @impl GenServer
  def handle_call({:limit, user_id}, _from, state) do
    {:reply, limit_for(state.config, user_id), state}
  end

  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = limit_for(state.config, user_id)
    {count, queue} = state.hits |> Map.get(user_id, {0, :queue.new()}) |> prune(now)

    if count < limit do
      hits = Map.put(state.hits, user_id, {count + 1, :queue.in(now, queue)})
      {:reply, {:ok, limit - count - 1}, %{state | hits: hits}}
    else
      {:value, oldest} = :queue.peek(queue)
      retry_after = oldest + @window_ms - now
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: Map.put(state.hits, user_id, {count, queue})}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    hits =
      Enum.reduce(state.hits, %{}, fn {user_id, entry}, acc ->
        case prune(entry, now) do
          {0, _queue} -> acc
          pruned -> Map.put(acc, user_id, pruned)
        end
      end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  defp limit_for(%{default: default, users: users}, user_id) do
    Map.get(users, user_id, default)
  end

  # Drops timestamps that have left the window.
  defp prune({count, queue}, now) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= now - @window_ms ->
        prune({count - 1, :queue.drop(queue)}, now)

      _ ->
        {count, queue}
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
