defmodule RateLimiter do
  @moduledoc ~S"""
  Per-user rate limiter: each user may make at most `N` requests in any
  rolling 60-second window.

  Limits are read from a term file when the limiter starts. The file holds a
  single map with a `:default` limit and a `:limits` map of per-user values:

      #{default => 60, limits => #{1 => 120, 42 => 5}}.

  Users not listed under `:limits` get `:default`. A limit of `0` rejects
  every request for that user. User IDs in the file must match the terms
  callers pass to `take/2` (for example, integer primary keys).

  ## Starting it

  Add the limiter to the supervision tree in `MyApp.Application`:

      children = [
        MyApp.Repo,
        {RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.term")},
        MyAppWeb.Endpoint
      ]

  If the file is missing or malformed, `start_link/1` fails and the boot
  fails with it, so a bad config is caught at deploy time rather than on the
  first request.

  ## Calling it

  Controllers and background jobs call `take/2` before doing the work.

  Controller:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case RateLimiter.take(user.id) do
            :ok ->
              {:ok, report} = Reports.generate(user, params)
              json(conn, %{id: report.id})

            {:error, {:rate_limited, retry_after_ms}} ->
              seconds = div(retry_after_ms + 999, 1000)

              conn
              |> put_resp_header("retry-after", Integer.to_string(seconds))
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  Background job (Oban worker, which accepts `{:snooze, seconds}`):

      defmodule MyApp.Workers.SyncExport do
        use Oban.Worker, queue: :exports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case RateLimiter.take(user_id) do
            :ok ->
              Exports.run(user_id)

            {:error, {:rate_limited, retry_after_ms}} ->
              {:snooze, div(retry_after_ms + 999, 1000)}
          end
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  @type user_id :: term()
  @type result :: :ok | {:error, {:rate_limited, pos_integer()}}

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` - required, path to the limits term file
    * `:name` - registered name, defaults to `RateLimiter`
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok` and counts the request. If the user is at their limit, returns
  `{:error, {:rate_limited, retry_after_ms}}` and does not count it.
  `retry_after_ms` is the time until the user's oldest counted request leaves
  the window.
  """
  @spec take(user_id(), GenServer.server()) :: result()
  def take(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:take, user_id})
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- load_config(Keyword.fetch!(opts, :config_path)) do
      schedule_sweep()
      {:ok, Map.put(config, :windows, %{})}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:take, user_id}, _from, state) do
    now = now_ms()
    limit = Map.get(state.limits, user_id, state.default)
    recent = take_recent(Map.get(state.windows, user_id, []), now)

    if length(recent) < limit do
      {:reply, :ok, put_window(state, user_id, [now | recent])}
    else
      retry_after = retry_after(recent, now)
      {:reply, {:error, {:rate_limited, retry_after}}, put_window(state, user_id, recent)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now_ms()

    windows =
      Enum.reduce(state.windows, %{}, fn {user_id, timestamps}, acc ->
        case take_recent(timestamps, now) do
          [] -> acc
          recent -> Map.put(acc, user_id, recent)
        end
      end)

    schedule_sweep()
    {:noreply, %{state | windows: windows}}
  end

  # Timestamps are stored newest first, so the expired ones are at the end.
  defp take_recent(timestamps, now) do
    Enum.take_while(timestamps, &(&1 > now - @window_ms))
  end

  defp retry_after([], _now), do: @window_ms
  defp retry_after(recent, now), do: List.last(recent) + @window_ms - now

  defp put_window(state, user_id, []) do
    %{state | windows: Map.delete(state.windows, user_id)}
  end

  defp put_window(state, user_id, timestamps) do
    %{state | windows: Map.put(state.windows, user_id, timestamps)}
  end

  defp load_config(path) do
    with {:ok, [%{default: default, limits: limits}]} when is_map(limits) <- :file.consult(path),
         true <- valid_limit?(default) and Enum.all?(Map.values(limits), &valid_limit?/1) do
      {:ok, %{default: default, limits: limits}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_config, path}}
    end
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
