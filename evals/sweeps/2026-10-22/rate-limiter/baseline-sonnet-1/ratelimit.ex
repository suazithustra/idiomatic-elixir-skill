defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any 60-second window. N comes from
  a JSON file read once when the limiter starts:

      {
        "default": 60,
        "users": { "42": 600, "17": 10 }
      }

  Users not listed in `"users"` get `"default"`.

  ## Starting

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job runner that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

  If the file is missing or malformed the limiter fails to start, which stops
  application boot rather than running with unknown limits.

  ## Calling

      case MyApp.RateLimiter.check(user.id) do
        {:ok, remaining} -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> reject()
      end

  `check/1` counts the request when it is allowed. Rejected requests are not
  counted.

  All checks go through one process, which keeps the count exact. It does a
  few map operations per call, so it is not a bottleneck at typical web
  traffic.
  """

  use GenServer

  @window_ms 60_000
  @sweep_ms 60_000

  ## Client API

  def start_link(opts) do
    path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{path: path, clock: opts[:clock]}, name: name)
  end

  @doc """
  Records a request for `user_id` if it is within its limit.

  Returns `{:ok, remaining}` or `{:error, {:rate_limited, retry_after_ms}}`.
  """
  @spec check(term(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  @doc "Returns the configured limit for `user_id`."
  @spec limit(term(), GenServer.server()) :: pos_integer()
  def limit(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:limit, to_string(user_id)})
  end

  ## Server

  @impl GenServer
  def init(%{path: path, clock: clock}) do
    case load_config(path) do
      {:ok, config} ->
        Process.send_after(self(), :sweep, @sweep_ms)

        {:ok,
         %{
           default: config.default,
           limits: config.users,
           clock: clock || (&monotonic_ms/0),
           # user_id => {count, :queue of request timestamps}
           hits: %{}
         }}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, path, reason}}
    end
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = state.clock.()
    limit = limit_for(state, user_id)
    {count, queue} = state.hits |> Map.get(user_id, {0, :queue.new()}) |> prune(now)

    if count < limit do
      hits = Map.put(state.hits, user_id, {count + 1, :queue.in(now, queue)})
      {:reply, {:ok, limit - count - 1}, %{state | hits: hits}}
    else
      {:value, oldest} = :queue.peek(queue)
      retry_after = max(oldest + @window_ms - now, 1)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: Map.put(state.hits, user_id, {count, queue})}}
    end
  end

  def handle_call({:limit, user_id}, _from, state) do
    {:reply, limit_for(state, user_id), state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = state.clock.()

    hits =
      for {user_id, entry} <- state.hits,
          {count, _} = pruned = prune(entry, now),
          count > 0,
          into: %{},
          do: {user_id, pruned}

    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp limit_for(state, user_id), do: Map.get(state.limits, user_id, state.default)

  defp prune({count, queue}, now) do
    case :queue.peek(queue) do
      {:value, ts} when ts <= now - @window_ms ->
        prune({count - 1, :queue.drop(queue)}, now)

      _ ->
        {count, queue}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp load_config(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- decode(body),
         {:ok, default} <- fetch_limit(json, "default"),
         {:ok, users} <- parse_users(Map.get(json, "users", %{})) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _} -> {:error, :not_an_object}
      {:error, reason} -> {:error, {:bad_json, reason}}
    end
  end

  defp fetch_limit(map, key) do
    case Map.fetch(map, key) do
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:bad_limit, key}}
    end
  end

  defp parse_users(users) when is_map(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {id, _}, {:ok, acc} ->
      case fetch_limit(users, id) do
        {:ok, n} -> {:cont, {:ok, Map.put(acc, id, n)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_users(_), do: {:error, {:bad_limit, "users"}}
end

# ---------------------------------------------------------------------------
# Caller examples (need Phoenix / Oban, so they are not compiled here).
#
# Controller, using a plug so every action is covered:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(%{assigns: %{current_user: user}} = conn, _opts) do
#         case MyApp.RateLimiter.check(user.id) do
#           {:ok, remaining} ->
#             put_resp_header(conn, "x-ratelimit-remaining", Integer.to_string(remaining))
#
#           {:error, {:rate_limited, retry_after_ms}} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
#             |> send_resp(429, "Too many requests")
#             |> halt()
#         end
#       end
#     end
#
#     # in a controller or router pipeline:
#     plug MyAppWeb.Plugs.RateLimit
#
# Background job (Oban): snooze until the window frees a slot.
#
#     defmodule MyApp.Workers.SyncAccount do
#       use Oban.Worker
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           {:ok, _remaining} -> MyApp.Accounts.sync(user_id)
#           {:error, {:rate_limited, ms}} -> {:snooze, max(ceil(ms / 1000), 1)}
#         end
#       end
#     end
# ---------------------------------------------------------------------------
