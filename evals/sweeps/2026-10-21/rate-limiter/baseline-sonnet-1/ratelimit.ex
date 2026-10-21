defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter.

  Each user may make at most N requests in any 60-second window. N comes from a
  JSON file read once, when the limiter starts:

      {"default": 60, "users": {"alice": 120, "bob": 10}}

  Users not listed in `users` get `default`.

  All checks go through one GenServer, so check-and-record is atomic. Request
  timestamps live in the server state and are pruned on each check and by a
  periodic sweep of idle users.

  ## Starting

  Add it to the application supervision tree, before the endpoint and any job
  workers that call it:

      children = [
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

  ## Using

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, retry_after_ms} -> reject(retry_after_ms)
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if it is under its limit.

  Returns `:ok`, or `{:error, retry_after_ms}` when the limit is reached. Rejected
  requests are not recorded.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, pos_integer()}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server

  @impl GenServer
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)
    config = load_config!(path)
    schedule_sweep()
    {:ok, %{config: config, hits: %{}}}
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = limit_for(state.config, user_id)
    recent = prune(Map.get(state.hits, user_id, []), now)

    if length(recent) < limit do
      {:reply, :ok, put_in(state.hits[user_id], [now | recent])}
    else
      # A limit of 0 leaves no timestamps; fall back to a full window.
      retry_after =
        case List.last(recent) do
          nil -> @window_ms
          oldest -> max(oldest + @window_ms - now, 1)
        end

      {:reply, {:error, retry_after}, put_in(state.hits[user_id], recent)}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      state.hits
      |> Map.new(fn {user_id, stamps} -> {user_id, prune(stamps, now)} end)
      |> Map.reject(fn {_user_id, stamps} -> stamps == [] end)

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  # Stamps are newest-first, so the expired ones are at the tail.
  defp prune(stamps, now) do
    cutoff = now - @window_ms
    Enum.take_while(stamps, &(&1 > cutoff))
  end

  defp limit_for(%{default: default, users: users}, user_id) do
    Map.get(users, to_string(user_id), default)
  end

  defp load_config!(path) do
    %{"default" => default, "users" => users} =
      path |> File.read!() |> JSON.decode!()

    unless valid_limit?(default) and Enum.all?(users, fn {_, n} -> valid_limit?(n) end) do
      raise ArgumentError, "rate limit config #{path}: limits must be non-negative integers"
    end

    %{default: default, users: users}
  end

  defp valid_limit?(n), do: is_integer(n) and n >= 0

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end

defmodule MyApp.Workers.ExportWorker do
  @moduledoc "Example background-job caller."

  def perform(%{user_id: user_id} = args) do
    case MyApp.RateLimiter.check(user_id) do
      :ok -> run_export(args)
      {:error, retry_after_ms} -> {:snooze, div(retry_after_ms, 1000) + 1}
    end
  end

  defp run_export(_args), do: :ok
end

# Example Phoenix caller (needs Phoenix/Plug, so not compiled here):
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(%{assigns: %{current_user: user}} = conn, _opts) do
#         case MyApp.RateLimiter.check(user.id) do
#           :ok ->
#             conn
#
#           {:error, retry_after_ms} ->
#             conn
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
#             |> send_resp(429, "Too many requests")
#             |> halt()
#         end
#       end
#     end
#
#     # router.ex
#     pipeline :api do
#       plug :accepts, ["json"]
#       plug MyAppWeb.Plugs.RateLimit
#     end
