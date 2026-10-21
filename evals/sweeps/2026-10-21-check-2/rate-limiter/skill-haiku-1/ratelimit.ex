defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling 60-second window.

  Each user's N comes from a JSON file read when the limiter starts. The file
  is one JSON object that maps user IDs to limits:

      {"42": 30, "7": 120}

  Keys are strings. Integer IDs are converted with `to_string/1`, so `42` and
  `"42"` name the same user. A user missing from the file gets
  `{:error, :unknown_user}`.

  ## Starting it

  Add the limiter to the supervision tree with the path to the file:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  ## Checking it

  Call `check/1` before doing the work. It returns `:ok` and records the
  request when the user is under the limit. Otherwise it returns an error and
  does not record the request.

      # Controller
      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            # ... do the work
          {:error, :rate_limited} ->
            send_resp(conn, :too_many_requests, "Too many requests")
          {:error, :unknown_user} ->
            send_resp(conn, :forbidden, "No rate limit configured")
        end
      end

      # Background job (Oban)
      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
          {:error, :unknown_user} -> {:discard, :unknown_user}
        end
      end

  A request counts once `check/1` returns `:ok`, even if the work after it
  fails.
  """

  use GenServer

  @window_ms 60_000

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter and reads its limits from the file at `:config_path`.

  Returns `{:error, reason}` when the file cannot be read, is not valid JSON,
  or does not map every user ID to a non-negative integer.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the process name and the ETS table name. Defaults to
      `MyApp.RateLimiter`. Pass a different name in tests to run a second
      instance.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Checks whether `user_id` may make another request, and records the request
  if so.

  Returns `:ok`, `{:error, :rate_limited}` when the user has used all of their
  requests in the last 60 seconds, or `{:error, :unknown_user}` when the file
  has no limit for the user.

  The check runs in the caller's process and reads an ETS table, so it does not
  wait on the limiter process.
  """
  @spec check(user_id(), atom()) :: :ok | {:error, :rate_limited | :unknown_user}
  def check(user_id, name \\ __MODULE__) do
    user = to_string(user_id)

    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> admit(name, {:requests, user}, limit)
      [] -> {:error, :unknown_user}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    case load_limits(Keyword.fetch!(opts, :config_path)) do
      {:ok, limit_objects} ->
        :ets.new(name, [
          :named_table,
          :public,
          :bag,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ets.insert(name, limit_objects)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:requests, :_}, {:"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp admit(name, key, limit) do
    now = System.monotonic_time(:millisecond)
    entry = {now, System.unique_integer([:positive, :monotonic])}

    # Record the request before counting. Counting first would let two
    # concurrent checks both see room and both pass. With this order they can
    # both be rejected at the limit, but never both admitted past it.
    :ets.insert(name, {key, entry})

    if count_recent(name, key, now) > limit do
      :ets.delete_object(name, {key, entry})
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp count_recent(name, key, now) do
    cutoff = now - @window_ms
    entries = :ets.lookup(name, key)
    Enum.count(entries, fn {_key, {ts, _ref}} -> ts > cutoff end)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  defp load_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      parse_limits(decoded)
    end
  end

  defp parse_limits(decoded) when is_map(decoded) do
    if Enum.all?(decoded, fn {_user, limit} -> is_integer(limit) and limit >= 0 end) do
      {:ok, Enum.map(decoded, fn {user, limit} -> {{:limit, user}, limit} end)}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_limits}
end
