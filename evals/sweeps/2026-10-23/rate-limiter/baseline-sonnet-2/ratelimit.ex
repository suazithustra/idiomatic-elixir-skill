defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  60 seconds.

  Limits are read once, when the process starts, from a JSON file:

      {
        "default": 60,
        "users": { "42": 120, "1001": 10 }
      }

  A user not listed under `"users"` gets the `"default"` limit. If the file is
  missing or malformed the process fails to start, so the app does not boot
  with no limits in force.

  All checks go through this one process, so a check-and-record is atomic and
  two callers can never both take the last slot.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job runners that use it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

  with, in `config/runtime.exs`:

      config :my_app, rate_limit_file: System.get_env("RATE_LIMIT_FILE", "priv/rate_limits.json")

  ## Calling it

      case MyApp.RateLimiter.check(user.id) do
        {:ok, _remaining} -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: term()
  @type result :: {:ok, remaining :: non_neg_integer()} | {:error, {:rate_limited, retry_after_ms :: pos_integer()}}

  ## Client API

  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config_path, name: name)
  end

  @doc """
  Records one request for `user_id` if it is under its limit.

  Returns `{:ok, remaining}` when the request is allowed (and counted), or
  `{:error, {:rate_limited, retry_after_ms}}` when it is not (and not counted).
  """
  @spec check(user_id(), GenServer.server()) :: result()
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  ## Server

  @impl GenServer
  def init(config_path) do
    case load_config(config_path) do
      {:ok, config} ->
        schedule_sweep()
        {:ok, %{config: config, hits: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, config_path, reason}}
    end
  end

  @impl GenServer
  def handle_call({:check, user}, _from, state) do
    now = now_ms()
    limit = limit_for(state.config, user)
    recent = prune(Map.get(state.hits, user, []), now)

    if length(recent) < limit do
      hits = Map.put(state.hits, user, [now | recent])
      {:reply, {:ok, limit - length(recent) - 1}, %{state | hits: hits}}
    else
      oldest = List.last(recent)
      retry_after = max(oldest + @window_ms - now, 1)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: Map.put(state.hits, user, recent)}}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      state.hits
      |> Map.new(fn {user, times} -> {user, prune(times, now)} end)
      |> Map.reject(fn {_user, times} -> times == [] end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  # Timestamps are kept newest-first.
  defp prune(times, now), do: Enum.take_while(times, &(&1 > now - @window_ms))

  defp limit_for(%{default: default, users: users}, user), do: Map.get(users, user, default)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_config(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- decode(body),
         {:ok, default} <- fetch_limit(json, "default"),
         {:ok, users} <- parse_users(Map.get(json, "users", %{})) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp decode(body) do
    case :json.decode(body) do
      %{} = map -> {:ok, map}
      _other -> {:error, :not_an_object}
    end
  rescue
    error -> {:error, {:invalid_json, Exception.message(error)}}
  end

  defp fetch_limit(map, key) do
    case Map.fetch(map, key) do
      {:ok, n} when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_limit, key}}
    end
  end

  defp parse_users(users) when is_map(users) do
    Enum.reduce_while(users, {:ok, %{}}, fn {user, _}, {:ok, acc} ->
      case fetch_limit(users, user) do
        {:ok, n} -> {:cont, {:ok, Map.put(acc, user, n)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_users(_other), do: {:error, :users_not_an_object}
end

defmodule MyApp.Jobs.SendDigest do
  @moduledoc "Example caller from a background job (Oban-style `perform/1`)."

  def perform(%{args: %{"user_id" => user_id}}) do
    case MyApp.RateLimiter.check(user_id) do
      {:ok, _remaining} -> deliver_digest(user_id)
      {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
    end
  end

  defp deliver_digest(_user_id), do: :ok
end

defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Example caller from a Phoenix pipeline. Assumes an earlier plug set
  `conn.assigns.current_user`.

      pipeline :api do
        plug :accepts, ["json"]
        plug MyAppWeb.Plugs.RateLimit
      end
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{current_user: user}} = conn, _opts) do
    case MyApp.RateLimiter.check(user.id) do
      {:ok, _remaining} ->
        conn

      {:error, {:rate_limited, retry_after_ms}} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
        |> send_resp(429, "Too many requests")
        |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
