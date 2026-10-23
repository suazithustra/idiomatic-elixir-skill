defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute.

  Every allowed request is recorded as one row in a public ETS table, so
  `check/2` runs in the caller's process and never waits on the owning
  GenServer. The GenServer only creates the tables, loads the per-user limits
  and sweeps expired rows.

  ## Limits file

  The file is read once, when the limiter starts, with `:file.consult/1`: one
  `{user_id, limit}.` term per line. Users missing from the file get the
  `:default_limit`. User IDs must not contain the atoms `:_` or `:"$1"`-style
  match variables, since they are used inside ETS match specs.

      {1, 100}.
      {2, 600}.
      {"service-account", 6000}.

  ## Starting it

  Add it to the supervision tree before the endpoint and the job processor:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_file: "priv/rate_limits.terms"},
        MyAppWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)

  ## Calling it

  From a controller, through a plug:

      defmodule MyAppWeb.RateLimitPlug do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, :rate_limited} ->
              conn
              |> put_resp_header("retry-after", "60")
              |> send_resp(429, "rate limit exceeded")
              |> halt()
          end
        end
      end

  From a background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @default_limit 60
  @sweep_interval :timer.seconds(30)

  @type user_id :: term()

  @doc """
  Starts the limiter and links it to the calling process.

  ## Options

    * `:limits_file` - path of the limits file. Required.
    * `:default_limit` - requests per minute for users not in the file.
      Defaults to `#{@default_limit}`.
    * `:name` - the name of the limiter, which must be an atom. Also names its
      ETS tables. Defaults to `#{inspect(__MODULE__)}`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_file, :name, default_limit: @default_limit])
    name = Keyword.get(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  A rejected request is not recorded, so it does not extend the user's wait.
  Concurrent requests right at the limit may both be rejected, never both
  allowed.

  ## Examples

      MyApp.RateLimiter.check(42)
      #=> :ok

      MyApp.RateLimiter.check(42)
      #=> {:error, :rate_limited}
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    row_key = {user_id, now, :erlang.unique_integer([:monotonic])}

    :ets.insert(name, {row_key})

    if count_since(name, user_id, now - @window_ms) <= limit(name, user_id) do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, opts}) do
    limits_file = Keyword.fetch!(opts, :limits_file)
    default_limit = Keyword.fetch!(opts, :default_limit)

    {:ok, limits} = read_limits(limits_file)

    :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
    :ets.new(limits_table(name), [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(limits_table(name), [{:default, default_limit} | limits])

    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    sweep(name)
    schedule_sweep()
    {:noreply, name}
  end

  defp read_limits(path) do
    case :file.consult(path) do
      {:ok, entries} -> validate_limits(entries)
      {:error, reason} -> {:error, {:limits_file, reason}}
    end
  end

  defp validate_limits(entries) do
    if Enum.all?(entries, &valid_entry?/1) do
      {:ok, entries}
    else
      {:error, {:limits_file, :invalid_entry}}
    end
  end

  defp valid_entry?({_user_id, limit}), do: is_integer(limit) and limit > 0
  defp valid_entry?(_entry), do: false

  defp limit(name, user_id) do
    case :ets.lookup(limits_table(name), user_id) do
      [{^user_id, limit}] -> limit
      [] -> :ets.lookup_element(limits_table(name), :default, 2)
    end
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp sweep(name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, match_spec)
  end

  defp limits_table(name), do: :"#{name}_limits"

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
