defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: at most N requests in any rolling 60 seconds.

  N comes from a JSON file read once, when the limiter starts:

      {
        "default": 60,
        "users": {"42": 600, "73": 10}
      }

  Users not listed under "users" get "default". Keys are user ids as strings;
  callers may pass integer ids, which are converted with `to_string/1`.

  All checks go through one GenServer so that counting and recording a request
  is a single step; concurrent callers cannot both take the last slot. Each
  check is a few microseconds of work, so one process is enough for typical
  web traffic. If it ever becomes the bottleneck, shard by user id across
  several of these processes.

  ## Starting

  Add it to the application's supervision tree, before the endpoint and any
  job runner that calls it:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

  ## Calling

      case MyApp.RateLimiter.check(user_id) do
        {:ok, remaining} -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> refuse(retry_after_ms)
      end

  See the end of this file for controller and job examples.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: String.t() | integer()
  @type result :: {:ok, remaining :: non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config_path, name: name)
  end

  @doc """
  Records one request for `user_id` if they are under their limit.

  Returns `{:ok, remaining}` when the request is allowed (and counted), or
  `{:error, {:rate_limited, retry_after_ms}}` when it is not (and not counted).
  """
  @spec check(user_id(), GenServer.server()) :: result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  ## Server

  @impl true
  def init(config_path) do
    case load_config(config_path) do
      {:ok, config} ->
        schedule_sweep()
        {:ok, %{default: config.default, limits: config.users, windows: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_config, config_path, reason}}
    end
  end

  @impl true
  def handle_call({:check, user}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user, state.default)
    {times, count} = prune(Map.get(state.windows, user, {:queue.new(), 0}), now)

    if count < limit do
      window = {:queue.in(now, times), count + 1}
      {:reply, {:ok, limit - count - 1}, put_in(state.windows[user], window)}
    else
      {:value, oldest} = :queue.peek(times)
      retry_after = max(oldest + @window_ms - now, 1)
      {:reply, {:error, {:rate_limited, retry_after}}, put_in(state.windows[user], {times, count})}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    windows =
      state.windows
      |> Map.new(fn {user, window} -> {user, prune(window, now)} end)
      |> Map.reject(fn {_user, {_times, count}} -> count == 0 end)

    schedule_sweep()
    {:noreply, %{state | windows: windows}}
  end

  ## Helpers

  # Drops timestamps that have left the rolling window.
  defp prune({times, count}, now) do
    cutoff = now - @window_ms

    case :queue.peek(times) do
      {:value, oldest} when oldest <= cutoff ->
        prune({:queue.drop(times), count - 1}, now)

      _ ->
        {times, count}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_config(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- decode(body),
         {:ok, default} <- fetch_limit(json, "default"),
         {:ok, users} <- fetch_users(Map.get(json, "users", %{})) do
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

  defp fetch_limit(json, key) do
    case Map.fetch(json, key) do
      {:ok, n} when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, {:bad_limit, key}}
    end
  end

  defp fetch_users(users) when is_map(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {user, n}, {:ok, acc} ->
      if is_integer(n) and n >= 0 do
        {:cont, {:ok, Map.put(acc, user, n)}}
      else
        {:halt, {:error, {:bad_limit, user}}}
      end
    end)
  end

  defp fetch_users(_), do: {:error, {:bad_limit, "users"}}
end

# ---------------------------------------------------------------------------
# Caller examples (need Phoenix/Plug, so they are not compiled here).
#
# Controller, as a plug:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(conn, _opts) do
#         case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
#           {:ok, _remaining} ->
#             conn
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
#     # in a controller or router pipeline, after authentication:
#     plug MyAppWeb.Plugs.RateLimit
#
# Background job (Oban worker):
#
#     defmodule MyApp.Workers.ExportReport do
#       use Oban.Worker, queue: :exports
#
#       @impl Oban.Worker
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           {:ok, _remaining} -> MyApp.Reports.export(user_id)
#           {:error, {:rate_limited, ms}} -> {:snooze, max(div(ms, 1000), 1)}
#         end
#       end
#     end
