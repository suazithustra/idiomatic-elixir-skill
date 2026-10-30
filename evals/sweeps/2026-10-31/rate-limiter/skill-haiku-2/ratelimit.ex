defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling minute.

  Limits are read once, when the limiter starts, from a JSON file:

      {"default_limit": 60, "user_limits": {"42": 300, "7": 10}}

  `default_limit` applies to every user not listed in `user_limits`. Keys in
  `user_limits` are user IDs written as strings. Integer IDs passed to
  `check/1` are converted to strings before the lookup.

  ## Starting

  Add the limiter to the supervision tree before the processes that call it:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"},
        MyAppWeb.Endpoint
      ]

  ## Checking

  Call `check/1` before doing the work. Controllers:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            json(conn, %{status: "accepted"})

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  Background jobs return the error to the job runner:

      def perform(user_id) do
        with :ok <- MyApp.RateLimiter.check(user_id), do: sync_contacts(user_id)
      end

  ## Design

  Each allowed or rejected request is one row in an ordered ETS table, keyed
  by user, time and a unique reference. A check inserts its own row first and
  then counts the user's rows in the last minute. If the count is over the
  limit, the check deletes its row and rejects. Because a row is inserted
  before it is counted, two concurrent checks cannot both read the same old
  count and both pass. A rejected request still counts for the moment it is
  in the table, so a concurrent check may be rejected when it would have been
  allowed. This never lets a user exceed the limit.

  Old rows are removed every minute. If the limiter restarts, its counts
  start from zero.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)
  @windows_table Module.concat(__MODULE__, Windows)
  @limits_table Module.concat(__MODULE__, Limits)

  @doc """
  Starts the limiter and loads its limits from the file at `:config_path`.

  Raises if the file cannot be read or does not hold valid limits, so a bad
  configuration stops the application at boot.
  """
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, config_path, name: __MODULE__)
  end

  @doc """
  Records one request for `user_id` and returns whether it may proceed.

  Returns `:ok` while the user is under their limit, and
  `{:error, :rate_limited}` once they reach it for the last minute.
  """
  @spec check(integer() | String.t()) :: :ok | {:error, :rate_limited}
  def check(user_id) when is_integer(user_id) or is_binary(user_id) do
    user_key = to_string(user_id)
    limit = limit_for(user_key)
    now = System.monotonic_time(:millisecond)
    row_key = {user_key, now, make_ref()}

    :ets.insert(@windows_table, {row_key, true})

    if count_in_window(user_key, now) <= limit do
      :ok
    else
      :ets.delete(@windows_table, row_key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(config_path) do
    :ets.new(@limits_table, [:named_table, :protected, :set])
    :ets.insert(@limits_table, load_limits!(config_path))

    :ets.new(@windows_table, [:named_table, :public, :ordered_set])
    schedule_sweep()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(System.monotonic_time(:millisecond))
    schedule_sweep()
    {:noreply, state}
  end

  defp limit_for(user_key) do
    case :ets.lookup(@limits_table, user_key) do
      [{^user_key, limit}] -> limit
      [] -> :ets.lookup_element(@limits_table, :default, 2)
    end
  end

  defp count_in_window(user_key, now) do
    oldest = now - @window_ms
    match_spec = [{{{user_key, :"$1", :_}, :_}, [{:>, :"$1", oldest}], [true]}]

    :ets.select_count(@windows_table, match_spec)
  end

  defp sweep(now) do
    expired = now - @window_ms
    match_spec = [{{{:_, :"$1", :_}, :_}, [{:"=<", :"$1", expired}], [true]}]

    :ets.select_delete(@windows_table, match_spec)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp load_limits!(config_path) do
    config = config_path |> File.read!() |> :json.decode()
    default = check_limit!(Map.fetch!(config, "default_limit"))
    user_limits = Map.get(config, "user_limits", %{})

    [{:default, default} | Enum.map(user_limits, &user_limit!/1)]
  end

  defp user_limit!({user_key, limit}), do: {user_key, check_limit!(limit)}

  defp check_limit!(limit) when is_integer(limit) and limit > 0, do: limit

  defp check_limit!(limit) do
    raise ArgumentError, "rate limit must be a positive integer, got: #{inspect(limit)}"
  end
end
