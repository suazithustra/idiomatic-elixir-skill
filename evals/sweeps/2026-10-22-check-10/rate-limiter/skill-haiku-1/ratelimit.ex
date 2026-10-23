defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a number of requests in a rolling minute.

  The limits come from a JSON file that is read when the limiter starts:

      {"default": 60, "users": {"42": 300, "7": 10}}

  `"default"` applies to every user not listed under `"users"`. User IDs given
  to `check/2` are converted with `to_string/1`, so `42` and `"42"` are the same
  user, and the keys under `"users"` are strings.

  Start the limiter in the supervision tree:

      children = [
        {MyApp.RateLimiter, limits_file: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  Call `check/2` before doing the work. A controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok -> do_create(conn, params)
          {:error, :rate_limited} -> send_resp(conn, 429, "Too many requests")
        end
      end

  A background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> run_export(job)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end

  ## How it counts

  A check records the request in an ETS table before it counts the user's
  requests in the last minute. A request over the limit removes its own record
  and returns `{:error, :rate_limited}`. Requests that pass are never removed by
  another check, so concurrent checks cannot let more than the limit through.
  They can reject a request that would have fit, which is the safe direction.
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @doc """
  Starts the limiter and reads its limits from `:limits_file`.

  ## Options

    * `:limits_file` - required. The path to the JSON file described in the module docs.
    * `:name` - an atom, the name of the process and of its ETS table. Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_file, name: __MODULE__])
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Records a request by `user_id` and returns `:ok`, or `{:error, :rate_limited}`
  when the user has already made as many requests as their limit allows in the
  last minute.

  `user_id` must be an integer or a string.
  """
  @spec check(integer() | String.t(), atom()) :: :ok | {:error, :rate_limited}
  def check(user_id, name \\ __MODULE__) do
    user_key = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    request = {user_key, now, System.unique_integer([:monotonic])}

    # Insert before counting, so that concurrent checks see each other's requests.
    :ets.insert(name, {request})

    if count_recent(name, user_key, now) <= limit_for(name, user_key) do
      :ok
    else
      :ets.delete(name, request)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    limits = opts |> Keyword.fetch!(:limits_file) |> read_limits!()

    :ets.new(name, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(name, limits)
    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp count_recent(name, user_key, now) do
    cutoff = now - @window
    :ets.select_count(name, [{{{user_key, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_key) do
    case :ets.lookup(name, {:limit, user_key}) do
      [{_key, limit}] -> limit
      [] -> default_limit(name)
    end
  end

  defp default_limit(name) do
    [{:default_limit, limit}] = :ets.lookup(name, :default_limit)
    limit
  end

  defp read_limits!(path) do
    config = path |> File.read!() |> JSON.decode!()
    users = Map.get(config, "users", %{})

    user_limits = for {user_id, limit} <- users, do: {{:limit, user_id}, limit}
    [{:default_limit, Map.fetch!(config, "default")} | user_limits]
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end
end
