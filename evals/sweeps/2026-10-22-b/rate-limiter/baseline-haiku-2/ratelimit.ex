defmodule RateLimiter do
  @moduledoc """
  Per-user sliding-window rate limiter.

  Each user may make at most N requests in any rolling 60 second window. N is
  read per user from a configuration file when the limiter starts. Users that
  are not listed in the file get the `default` limit from that file.

  ## Configuration file

  The file holds a single Erlang term ending in a period. User IDs are compared
  with `==` against the IDs passed to `allow/2`, so use the same type for both
  (strings here):

      %{
        default: 60,
        users: %{
          "alice" => 300,
          "bob" => 10
        }
      }.

  ## Starting it

  Add it to the supervision tree, pointing at the config file:

      # lib/my_app/application.ex
      children = [
        {RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_config)},
        MyAppWeb.Endpoint
      ]

  If the file is missing or invalid, `start_link/1` returns an error and the
  application fails to boot, so a bad config is caught at deploy time.

  ## Callers

  Controllers:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case RateLimiter.allow(user.id) do
            :ok ->
              report = Reports.generate!(user, params)
              json(conn, %{id: report.id})

            {:error, :rate_limited, retry_after_ms} ->
              conn
              |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000) + 1))
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limited"})
          end
        end
      end

  Background jobs (for example an Oban worker). Returning `{:snooze, seconds}`
  reschedules the job instead of failing it:

      defmodule MyApp.Workers.Export do
        use Oban.Worker, queue: :exports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
          case RateLimiter.allow(user_id) do
            :ok ->
              Exports.run(args)

            {:error, :rate_limited, retry_after_ms} ->
              {:snooze, div(retry_after_ms, 1000) + 1}
          end
        end
      end

  `allow/2` records the request when it returns `:ok`, so call it once per unit
  of work, right before doing the work.
  """

  use GenServer

  @window_ms 60_000
  @cleanup_interval_ms 60_000

  # Client API

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` (required) - path to the limits file described in the module docs
    * `:name` - registered name, defaults to `#{__MODULE__}`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks whether `user_id` may make another request. If so, the request is
  recorded and `:ok` is returned. Otherwise returns how long the caller should
  wait before the next request would be allowed.
  """
  @spec allow(term(), GenServer.server()) :: :ok | {:error, :rate_limited, pos_integer()}
  def allow(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:allow, user_id})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)

    case load_config(path) do
      {:ok, config} ->
        schedule_cleanup()
        {:ok, %{config: config, requests: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, path, reason}}
    end
  end

  @impl true
  def handle_call({:allow, user_id}, _from, state) do
    now = now_ms()
    limit = limit_for(state.config, user_id)
    timestamps = state.requests |> Map.get(user_id, []) |> prune(now)

    if length(timestamps) < limit do
      {:reply, :ok, put_timestamps(state, user_id, [now | timestamps])}
    else
      {:reply, {:error, :rate_limited, retry_after(timestamps, now)},
       put_timestamps(state, user_id, timestamps)}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = now_ms()

    requests =
      state.requests
      |> Map.new(fn {user_id, timestamps} -> {user_id, prune(timestamps, now)} end)
      |> Map.reject(fn {_user_id, timestamps} -> timestamps == [] end)

    schedule_cleanup()
    {:noreply, %{state | requests: requests}}
  end

  # Helpers

  defp load_config(path) do
    with {:ok, term} <- read_term(path), do: validate(term)
  end

  defp read_term(path) do
    case :file.consult(path) do
      {:ok, [term]} -> {:ok, term}
      {:ok, _terms} -> {:error, :expected_single_term}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(%{default: default, users: users}) when is_map(users) do
    if valid_limit?(default) and Enum.all?(Map.values(users), &valid_limit?/1) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp validate(_term), do: {:error, :invalid_config_shape}

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0

  defp limit_for(%{default: default, users: users}, user_id) do
    Map.get(users, user_id, default)
  end

  # Timestamps are kept newest first, so everything outside the window is a
  # suffix that `take_while` stops before.
  defp prune(timestamps, now) do
    Enum.take_while(timestamps, &(&1 > now - @window_ms))
  end

  # With the list pruned and at the limit, the oldest entry decides when a slot
  # frees up. With a limit of 0 the list is always empty.
  defp retry_after([], _now), do: @window_ms

  defp retry_after(timestamps, now) do
    max(List.last(timestamps) + @window_ms - now, 1)
  end

  defp put_timestamps(state, user_id, []) do
    %{state | requests: Map.delete(state.requests, user_id)}
  end

  defp put_timestamps(state, user_id, timestamps) do
    %{state | requests: Map.put(state.requests, user_id, timestamps)}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
