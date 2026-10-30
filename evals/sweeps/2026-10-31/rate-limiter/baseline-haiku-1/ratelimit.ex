defmodule MyApp.RateLimit do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any rolling
  60-second window. N comes from a config file that is read once, when the
  limiter starts.

  ## Config file

  The file holds Erlang terms, one per line, each ending with a period. Use
  binaries (`<<"...">>`) for string user IDs, because `"..."` is read as a
  charlist:

      {default, 60}.
      {42, 300}.
      {<<"user-abc">>, 10}.

  `{default, N}` sets the limit for every user not listed. If it is missing,
  unlisted users get #{60} requests per minute. Each N must be a positive integer.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`:

      children = [
        {MyApp.RateLimit,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.terms")}
      ]

  If the file cannot be read or contains a bad entry, the process fails to
  start, so the application does not boot with missing limits.

  ## Using it

  Call `hit/1` before doing the work. Only allowed requests are counted.
  Rejected requests do not use up a slot. See the examples at the end of this
  file.
  """

  use GenServer

  @window_ms 60_000
  @fallback_limit 60
  @sweep_interval_ms 60_000

  @type user_id :: term()
  @type result :: :ok | {:error, {:rate_limited, retry_after_seconds :: pos_integer()}}

  @doc """
  Starts the limiter. Options:

    * `:config_path` (required) - path to the limits file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Counts one request for `user_id` if the user is under their limit.

  Returns `:ok`, or `{:error, {:rate_limited, seconds}}` where `seconds` is the
  time until the user can make another request.
  """
  @spec hit(user_id(), GenServer.server()) :: result()
  def hit(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:hit, user_id})
  end

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)

    case load_config(path) do
      {:ok, default, limits} ->
        schedule_sweep()
        {:ok, %{default: default, limits: limits, hits: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:hit, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits, user_id, state.default)

    # Timestamps are stored newest first.
    timestamps = state.hits |> Map.get(user_id, []) |> prune(now)
    state = put_in(state, [:hits, user_id], timestamps)

    if length(timestamps) < limit do
      {:reply, :ok, put_in(state, [:hits, user_id], [now | timestamps])}
    else
      # The oldest request in the window leaves first, so wait for it.
      oldest = List.last(timestamps)
      retry_ms = oldest + @window_ms - now
      {:reply, {:error, {:rate_limited, ceil_seconds(retry_ms)}}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    # Drop users whose requests have all left the window, so memory does not grow
    # with every user who has ever called.
    now = System.monotonic_time(:millisecond)

    hits =
      state.hits
      |> Enum.map(fn {user_id, timestamps} -> {user_id, prune(timestamps, now)} end)
      |> Enum.reject(fn {_user_id, timestamps} -> timestamps == [] end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  defp prune(timestamps, now) do
    cutoff = now - @window_ms
    Enum.take_while(timestamps, &(&1 > cutoff))
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp ceil_seconds(ms), do: max(div(ms + 999, 1000), 1)

  defp load_config(path) do
    case :file.consult(path) do
      {:ok, terms} -> parse_terms(terms)
      {:error, reason} -> {:error, {:config_read_failed, path, reason}}
    end
  end

  defp parse_terms(terms) do
    Enum.reduce_while(terms, {:ok, @fallback_limit, %{}}, fn
      {:default, n}, {:ok, _default, limits} when is_integer(n) and n > 0 ->
        {:cont, {:ok, n, limits}}

      {user_id, n}, {:ok, default, limits} when is_integer(n) and n > 0 ->
        {:cont, {:ok, default, Map.put(limits, user_id, n)}}

      entry, _acc ->
        {:halt, {:error, {:invalid_config_entry, entry}}}
    end)
  end
end

# ---------------------------------------------------------------------------
# Caller example: Phoenix controller (not compiled here; Phoenix is not installed)
# ---------------------------------------------------------------------------
#
# defmodule MyAppWeb.ReportController do
#   use MyAppWeb, :controller
#
#   alias MyApp.RateLimit
#
#   def create(conn, params) do
#     user = conn.assigns.current_user
#
#     case RateLimit.hit(user.id) do
#       :ok ->
#         report = Reports.generate!(user, params)
#         json(conn, %{id: report.id})
#
#       {:error, {:rate_limited, retry_after}} ->
#         conn
#         |> put_resp_header("retry-after", Integer.to_string(retry_after))
#         |> put_status(:too_many_requests)
#         |> json(%{error: "rate_limited", retry_after: retry_after})
#     end
#   end
# end
#
# ---------------------------------------------------------------------------
# Caller example: Oban background job (not compiled here; Oban is not installed)
# ---------------------------------------------------------------------------
#
# defmodule MyApp.Workers.ExportWorker do
#   use Oban.Worker, queue: :exports
#
#   alias MyApp.RateLimit
#
#   @impl Oban.Worker
#   def perform(%Oban.Job{args: %{"user_id" => user_id, "export_id" => export_id}}) do
#     case RateLimit.hit(user_id) do
#       :ok -> Exports.run(export_id)
#       {:error, {:rate_limited, retry_after}} -> {:snooze, retry_after}
#     end
#   end
# end
