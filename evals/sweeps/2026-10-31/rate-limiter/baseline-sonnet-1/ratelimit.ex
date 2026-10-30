defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any 60 second window. N comes from
  a JSON file read once when the limiter starts:

      {"default": 60, "users": {"42": 600, "alice": 10}}

  Users not listed under "users" get the "default" limit. User ids may be
  integers or strings; they are compared as strings.

  The limiter is a single GenServer, so checks are serialized and the
  count-then-record step cannot race between callers.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job runners that use it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint
      ]

  If the file is missing or malformed, `start_link/1` fails and the
  application does not boot.

  ## Calling it

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Client API

  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config_path, name: name)
  end

  @doc """
  Records a request for `user_id` if it is under its limit.

  Returns `:ok` when the request is allowed and counted, or
  `{:error, {:rate_limited, retry_after_ms}}` when the limit is reached. A
  rejected request is not counted.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  ## Server

  @impl true
  def init(config_path) do
    %{default: default, users: users} = load_config!(config_path)
    schedule_sweep()
    {:ok, %{default: default, limits: users, hits: %{}}}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_id, state.default)
    hits = state.hits |> Map.get(user_id, :queue.new()) |> prune(now)

    if :queue.len(hits) < limit do
      {:reply, :ok, put_in(state.hits[user_id], :queue.in(now, hits))}
    else
      retry_after =
        case :queue.peek(hits) do
          {:value, oldest} -> max(oldest + @window_ms - now, 1)
          :empty -> @window_ms
        end

      {:reply, {:error, {:rate_limited, retry_after}}, put_in(state.hits[user_id], hits)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      state.hits
      |> Map.new(fn {user_id, q} -> {user_id, prune(q, now)} end)
      |> Map.reject(fn {_user_id, q} -> :queue.is_empty(q) end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  # Drops timestamps that have left the rolling window.
  defp prune(queue, now) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= now - @window_ms -> queue |> :queue.drop() |> prune(now)
      _ -> queue
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_config!(path) do
    %{"default" => default} = config = path |> File.read!() |> JSON.decode!()
    users = Map.get(config, "users", %{})

    unless valid_limit?(default) and Enum.all?(users, fn {_, n} -> valid_limit?(n) end) do
      raise ArgumentError, "rate limit config #{path}: limits must be non-negative integers"
    end

    %{default: default, users: users}
  end

  defp valid_limit?(n), do: is_integer(n) and n >= 0
end

defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Example caller: a controller-level plug. Requires Phoenix/Plug, so it is
  not compiled here.

      # in a controller or router pipeline
      plug MyAppWeb.Plugs.RateLimit
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{current_user: user}} = conn, _opts) do
    case MyApp.RateLimiter.check(user.id) do
      :ok ->
        conn

      {:error, {:rate_limited, retry_after_ms}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
        |> send_resp(429, "Too many requests")
        |> halt()
    end
  end
end

defmodule MyApp.Workers.ExportWorker do
  @moduledoc """
  Example caller: a background job (Oban-style `perform/1`).
  """

  def perform(%{args: %{"user_id" => user_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> run_export(user_id)
      {:error, {:rate_limited, retry_after_ms}} -> {:snooze, max(div(retry_after_ms, 1000), 1)}
    end
  end

  defp run_export(_user_id), do: :ok
end
