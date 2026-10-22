defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests per rolling minute.

  N for each user is read once, when the limiter starts, from a limits file with
  one `user_id,limit` line per user (user ids are integers):

      1,100
      2,10

  Users missing from the file get the `:default_limit`.

  Every hit is a row in a public ETS table owned by this process, so callers
  check the limit from their own process without waiting on the GenServer. The
  owner process only creates the table, loads the limits and sweeps old hits.

  ## Starting

  Add it to the application's supervision tree, before the endpoint and any
  job runner that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_path: "priv/rate_limits.csv", default_limit: 60},
        MyAppWeb.Endpoint
      ]

  ## Calling

  A controller, as a plug:

      plug :rate_limit when action in [:create, :update]

      defp rate_limit(conn, _opts) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            conn

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate limit exceeded"})
            |> halt()
        end
      end

  A background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_path` - path of the limits file. Required.
    * `:default_limit` - requests per minute for users not in the file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to `#{inspect(__MODULE__)}`.
    * `:sweep_interval` - milliseconds between removals of expired hits.
      Defaults to #{@sweep_interval_ms}.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, :default_limit, :name, :sweep_interval])
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's
  limit for the last minute, or `{:error, :rate_limited}` if it is not.

  A rejected request is not counted against the user.

  Pass the limiter's `:name` as the first argument to use a non-default instance.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    limit = limit_for(name, user_id)
    now = System.monotonic_time(:millisecond)
    hit = {:hit, user_id, now, :erlang.unique_integer([:monotonic])}

    # Insert first and count afterwards: a read-then-write would let
    # concurrent requests all see room and all be admitted.
    true = :ets.insert(name, {hit})

    if hits_since(name, user_id, now - @window_ms) <= limit do
      :ok
    else
      :ets.delete(name, hit)
      {:error, :rate_limited}
    end
  end

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp hits_since(name, user_id, cutoff) do
    match_spec = [{{{:hit, user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    sweep_interval = Keyword.get(opts, :sweep_interval, @sweep_interval_ms)

    limits = load_limits!(Keyword.fetch!(opts, :limits_path))

    :ets.new(name, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(name, {:default_limit, Keyword.fetch!(opts, :default_limit)})
    :ets.insert(name, Enum.map(limits, fn {user_id, limit} -> {{:limit, user_id}, limit} end))

    Process.send_after(self(), :sweep, sweep_interval)

    {:ok, %{name: name, sweep_interval: sweep_interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:hit, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(state.name, match_spec)

    Process.send_after(self(), :sweep, state.sweep_interval)

    {:noreply, state}
  end

  # Boot-time setup: a missing or malformed file is a deployment bug, so it
  # raises and keeps the application from starting with the wrong limits.
  defp load_limits!(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(&parse_line!/1)
  end

  defp parse_line!(line) do
    [user_id, limit] = String.split(line, ",", parts: 2)

    {String.to_integer(String.trim(user_id)), String.to_integer(String.trim(limit))}
  end
end
