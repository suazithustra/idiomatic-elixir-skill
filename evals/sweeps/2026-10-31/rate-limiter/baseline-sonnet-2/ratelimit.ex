defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: at most N requests per rolling minute.

  N is set per user in a config file that is read once, when the limiter
  starts. The file is an Elixir script (`.exs`) that returns a map:

      # config/rate_limits.exs
      %{
        default: 60,
        users: %{
          "alice" => 120,
          "bot-7" => 10
        }
      }

  Users not listed under `:users` get the `:default` limit.

  All checks go through one process, so counting is exact and callers on any
  node-local process (controllers, Oban/background jobs) see the same state.
  The state is in memory only: a restart clears all counters, and the config
  is not reloaded until the process restarts.

  ## Starting it

  Add it to the application supervision tree, before the endpoint and any
  job runner that calls it:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.exs")},
        MyAppWeb.Endpoint
      ]

  If the file is missing or malformed, the limiter fails to start and so does
  the application.

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case MyApp.RateLimiter.check(user.id) do
            {:ok, _remaining} ->
              {:ok, report} = MyApp.Reports.generate(user, params)
              json(conn, report)

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(ceil(retry_after_ms / 1000)))
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.Export do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            {:ok, _remaining} -> MyApp.Exports.run(user_id)
            {:error, {:rate_limited, retry_after_ms}} ->
              {:snooze, max(div(retry_after_ms, 1000), 1)}
          end
        end
      end
  """

  use GenServer

  @window_ms 60_000

  @type user_id :: term()

  ## Client API

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the limits file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, config_path, name: name)
  end

  @doc """
  Records one request for `user_id` if it is within the limit.

  Returns `{:ok, remaining}` when the request is allowed, or
  `{:error, {:rate_limited, retry_after_ms}}` when it is not. A rejected
  request is not counted.
  """
  @spec check(user_id(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, user_id})
  end

  ## Server callbacks

  @impl GenServer
  def init(config_path) do
    {config, _bindings} = Code.eval_file(config_path)
    {:ok, %{default: default, users: users}} = validate(config)

    schedule_sweep()
    {:ok, %{default: default, limits: users, hits: %{}}}
  end

  @impl GenServer
  def handle_call({:check, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_id, state.default)
    recent = prune(Map.get(state.hits, user_id, []), now)

    if length(recent) < limit do
      recent = [now | recent]
      {:reply, {:ok, limit - length(recent)}, put_in(state.hits[user_id], recent)}
    else
      # `recent` is newest-first, so the last entry is the one that expires first.
      retry_after = List.last(recent) + @window_ms - now
      {:reply, {:error, {:rate_limited, max(retry_after, 1)}}, put_in(state.hits[user_id], recent)}
    end
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = now_ms()

    hits =
      for {user_id, stamps} <- state.hits,
          recent = prune(stamps, now),
          recent != [],
          into: %{},
          do: {user_id, recent}

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  defp validate(%{default: default, users: users} = config)
       when is_integer(default) and default >= 0 and is_map(users) do
    if Enum.all?(users, fn {_id, n} -> is_integer(n) and n >= 0 end) do
      {:ok, config}
    else
      raise ArgumentError, "rate limit config: every user limit must be a non-negative integer"
    end
  end

  defp validate(other) do
    raise ArgumentError,
          "rate limit config must be a map with :default (integer) and :users (map), got: #{inspect(other)}"
  end

  # Drops timestamps that have left the rolling window. Input is newest-first.
  defp prune(stamps, now) do
    Enum.take_while(stamps, &(&1 > now - @window_ms))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Removes users with no recent requests so memory does not grow without bound.
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)
end
