defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling minute. N comes from a JSON
  file that is read when the limiter starts.

  Callers run `check/2` in their own process. The counts live in a public ETS
  table (an in-memory table that any process can read and write), and the
  limiter process owns that table and sweeps old entries out of it.

  Concurrent requests may be refused when the user is at the limit, but
  never let through past it.

  ## Configuration file

      {
        "default": 60,
        "users": {"42": 300, "7": 10}
      }

  `default` applies to every user not listed under `users`. User ids are
  matched as strings, so the integer id 42 matches `"42"`.

  ## Starting

  Add the limiter to the supervision tree:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  ## Example

  In a controller:

      case MyApp.RateLimiter.check(current_user.id) do
        :ok ->
          render_report(conn, report)

        {:error, :rate_limited} ->
          conn
          |> put_status(:too_many_requests)
          |> json(%{error: "rate_limited"})
      end

  In a background job, return an error so the job can retry later:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(10)

  @doc """
  Starts the limiter and reads its limits from the file at `:config_path`.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - name of the process and of its ETS table. Defaults to
      `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Counts one request for `user_id` and returns `:ok` if it is within the
  user's limit.

  A refused request is not counted, so a user who keeps retrying does not
  push back the time when their next request is allowed.
  """
  @spec check(String.t() | integer(), GenServer.name()) :: :ok | {:error, :rate_limited}
  def check(user_id, name \\ __MODULE__) do
    user = user_key(user_id)
    now = System.monotonic_time(:millisecond)
    row = {user, now, System.unique_integer([:monotonic, :positive])}

    # Insert first and count second. Two requests that race each see the
    # other's row, so each one counts itself. Refusing a request that a
    # lookup-then-write would have allowed is the safe error here.
    :ets.insert(name, {row, true})

    limit = limit_for(name, user)
    count = count_in_window(name, user, now)

    if count > limit do
      :ets.delete(name, row)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    :ets.new(name, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    load_limits(name, config_path)
    schedule_sweep()

    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    delete_expired(name, System.monotonic_time(:millisecond))
    schedule_sweep()

    {:noreply, name}
  end

  defp user_key(user_id) when is_integer(user_id) or is_binary(user_id) do
    to_string(user_id)
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, {:limit, :default}, 2)
    end
  end

  # Request rows are keyed {user, time, unique}. Limit rows are keyed
  # {:limit, user}, a 2-tuple, so the match specs below never touch them.
  defp count_in_window(name, user, now) do
    cutoff = now - @window_ms

    :ets.select_count(name, [{{{user, :"$1", :_}, :_}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp delete_expired(name, now) do
    cutoff = now - @window_ms

    :ets.select_delete(name, [{{{:_, :"$1", :_}, :_}, [{:"=<", :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp load_limits(name, config_path) do
    config = config_path |> File.read!() |> :json.decode()
    %{"default" => default} = config
    users = Map.get(config, "users", %{})

    rows = [{{:limit, :default}, validate_limit!(default)} | Enum.map(users, &user_limit_row/1)]

    :ets.insert(name, rows)
  end

  defp user_limit_row({user, limit}), do: {{:limit, user}, validate_limit!(limit)}

  defp validate_limit!(limit) when is_integer(limit) and limit >= 0, do: limit

  defp validate_limit!(other) do
    raise ArgumentError, "rate limit must be a non-negative integer, got: #{inspect(other)}"
  end
end
