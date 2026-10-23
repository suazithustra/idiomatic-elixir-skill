defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rolling-window rate limiter: at most N requests per user in any
  trailing 60 seconds.

  ## Configuration

  Per-user limits are read once, when the limiter starts, from an Elixir
  term file (trusted, evaluated with `Code.eval_file/1`):

      # config/rate_limits.exs
      %{
        default: 60,
        users: %{
          42 => 600,
          "service-account" => 6000
        }
      }

  Users not listed in `:users` get `:default`. The path comes from the
  `:limits_file` start option or from
  `config :my_app, MyApp.RateLimiter, limits_file: "config/rate_limits.exs"`.
  A missing or malformed file makes the limiter fail to start, so a bad
  deploy is caught immediately.

  ## Starting it

  Add it to the application's supervision tree before anything that calls it
  (before the endpoint and job processors):

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_file: "config/rate_limits.exs"},
        MyAppWeb.Endpoint
      ]

  ## Calling it

      case MyApp.RateLimiter.check(user.id) do
        {:ok, remaining} -> do_work()
        {:error, {:rate_limited, retry_after_ms}} -> back_off(retry_after_ms)
      end

  `check/1` both tests and records the request in one atomic step, so callers
  never need a separate "increment" call.

  ## Design

  A single GenServer serializes all checks, which makes check-and-record
  atomic without locks. Each user's recent request times are kept newest
  first and pruned on every check; a periodic sweep drops users whose
  history has fully expired so memory stays bounded.
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: term()
  @type result ::
          {:ok, remaining :: non_neg_integer()}
          | {:error, {:rate_limited, retry_after_ms :: pos_integer()}}

  ## Client API

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Records a request for `user_id` if allowed, and reports whether it was."
  @spec check(user_id(), GenServer.server()) :: result()
  def check(user_id, server \\ __MODULE__), do: GenServer.call(server, {:check, user_id})

  @doc "The configured per-minute limit for `user_id`."
  @spec limit_for(user_id(), GenServer.server()) :: pos_integer()
  def limit_for(user_id, server \\ __MODULE__), do: GenServer.call(server, {:limit_for, user_id})

  ## Server

  @impl true
  def init(opts) do
    path =
      Keyword.get_lazy(opts, :limits_file, fn ->
        :my_app
        |> Application.get_env(__MODULE__, [])
        |> Keyword.fetch!(:limits_file)
      end)

    %{default: default, users: users} = load_limits!(path)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{default: default, users: users, hits: %{}, clock: clock}}
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = state.clock.()
    limit = limit(state, user_id)
    recent = prune(Map.get(state.hits, user_id, []), now)

    if length(recent) < limit do
      hits = Map.put(state.hits, user_id, [now | recent])
      {:reply, {:ok, limit - length(recent) - 1}, %{state | hits: hits}}
    else
      retry_after = max(List.last(recent) + @window_ms - now, 1)
      hits = Map.put(state.hits, user_id, recent)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: hits}}
    end
  end

  def handle_call({:limit_for, user_id}, _from, state), do: {:reply, limit(state, user_id), state}

  @impl true
  def handle_info(:sweep, state) do
    now = state.clock.()

    hits =
      state.hits
      |> Map.new(fn {user, times} -> {user, prune(times, now)} end)
      |> Map.reject(fn {_user, times} -> times == [] end)

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp limit(state, user_id), do: Map.get(state.users, user_id, state.default)

  # Times are newest first, so everything past the first expired entry is expired too.
  defp prune(times, now), do: Enum.take_while(times, &(&1 > now - @window_ms))

  defp load_limits!(path) do
    {config, _bindings} = Code.eval_file(path)

    with %{default: default} <- config,
         users = Map.get(config, :users, %{}),
         true <- valid_limit?(default),
         true <- is_map(users) and Enum.all?(users, fn {_, n} -> valid_limit?(n) end) do
      %{default: default, users: users}
    else
      _ -> raise ArgumentError, "invalid rate limit config in #{path}: #{inspect(config)}"
    end
  end

  defp valid_limit?(n), do: is_integer(n) and n > 0
end

# ---------------------------------------------------------------------------
# Example callers (need Phoenix / Oban, so shown as comments).
#
# Application supervision tree:
#
#     # lib/my_app/application.ex
#     def start(_type, _args) do
#       children = [
#         MyApp.Repo,
#         {MyApp.RateLimiter, limits_file: "config/rate_limits.exs"},
#         MyAppWeb.Endpoint
#       ]
#
#       Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
#     end
#
# Controller (as a plug so every action is covered):
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
#             |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
#             |> send_resp(429, "Too Many Requests")
#             |> halt()
#         end
#       end
#     end
#
#     # in a controller:  plug MyAppWeb.Plugs.RateLimit
#
# Background job (Oban):
#
#     defmodule MyApp.Workers.SyncAccount do
#       use Oban.Worker
#
#       @impl true
#       def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#         case MyApp.RateLimiter.check(user_id) do
#           {:ok, _remaining} -> MyApp.Accounts.sync(user_id)
#           {:error, {:rate_limited, ms}} -> {:snooze, max(div(ms, 1000), 1)}
#         end
#       end
#     end
