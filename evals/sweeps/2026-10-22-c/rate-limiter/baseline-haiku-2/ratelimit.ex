defmodule RateLimiter do
  @moduledoc """
  Per-user rate limiter over a rolling one-minute window.

  Each user may make at most `N` requests in any rolling 60 second window.
  `N` is looked up per user in a JSON configuration file that is read once,
  when the limiter starts:

      {
        "default": 60,
        "users": {
          "42": 300,
          "97": 10
        }
      }

  Users not listed under `"users"` get `"default"`. Keys under `"users"` are
  user ids as strings.

  ## Starting it

  Add it to your supervision tree, pointing at the config file:

      # lib/my_app/application.ex
      children = [
        {RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  If the file is missing or malformed, `start_link/1` fails and the
  supervisor reports it at boot.

  ## Checking it

  Call `check/1` before doing the work. A `:rate_limited` result does not
  record a request.

      # Controller
      def create(conn, params) do
        case RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            do_create(conn, params)

          {:error, :rate_limited, retry_after_ms} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
            |> send_resp(429, "Too many requests")
        end
      end

      # Background job (Oban)
      def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
        case RateLimiter.check(user_id) do
          :ok ->
            do_work(args)

          {:error, :rate_limited, retry_after_ms} ->
            {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms 60_000

  @type user_id :: term()

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the JSON configuration file.
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is under that user's limit.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` where
  `retry_after_ms` is how long until the next request would be accepted.
  """
  @spec check(GenServer.server(), user_id()) :: :ok | {:error, :rate_limited, pos_integer()}
  def check(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:check, user_id})
  end

  @impl true
  def init(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    {default_limit, user_limits} = load_config!(config_path)

    schedule_sweep()

    {:ok,
     %{
       default_limit: default_limit,
       user_limits: user_limits,
       # user_id => request timestamps (monotonic ms), newest first
       hits: %{}
     }}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    window_start = now - @window_ms
    limit = Map.get(state.user_limits, to_string(user_id), state.default_limit)
    recent = state.hits |> Map.get(user_id, []) |> Enum.take_while(&(&1 > window_start))

    if length(recent) < limit do
      {:reply, :ok, put_hits(state, user_id, [now | recent])}
    else
      # Full window: the slot frees when the oldest kept request leaves it.
      retry_after_ms = List.last(recent) + @window_ms - now
      {:reply, {:error, :rate_limited, retry_after_ms}, put_hits(state, user_id, recent)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    window_start = now_ms() - @window_ms

    hits =
      state.hits
      |> Map.new(fn {user_id, timestamps} ->
        {user_id, Enum.take_while(timestamps, &(&1 > window_start))}
      end)
      |> Map.reject(fn {_user_id, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  defp load_config!(path) do
    config = path |> File.read!() |> :json.decode()

    default = positive_integer!(Map.fetch!(config, "default"))

    users =
      config
      |> Map.get("users", %{})
      |> Map.new(fn {user_id, limit} -> {user_id, positive_integer!(limit)} end)

    {default, users}
  end

  defp positive_integer!(n) when is_integer(n) and n > 0, do: n

  defp positive_integer!(n) do
    raise ArgumentError, "rate limits must be positive integers, got: #{inspect(n)}"
  end

  defp put_hits(state, user_id, timestamps) do
    %{state | hits: Map.put(state.hits, user_id, timestamps)}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
