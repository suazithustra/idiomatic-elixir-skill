defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N per user comes from a limits file read once, when the limiter starts. The file is an
  Elixir term file holding a map of user id to limit:

      %{1 => 100, 2 => 20, "service-account" => 1000}

  Users missing from the file get the `:default_limit` option.

  Every request is stored as one row in a public ETS table, so callers check the limit from
  their own process and never queue behind a single process. The owning GenServer only
  creates the tables and periodically removes expired rows.

  ## Starting it

  Add it to the supervision tree before anything that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_path: "priv/rate_limits.exs", default_limit: 60},
        MyAppWeb.Endpoint
      ]

  The `:limits_path` option falls back to `Application.get_env(:my_app, :rate_limits_path)`.

  ## Calling it from a controller

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            # do the work
            send_resp(conn, 201, "")

          {:error, :rate_limited} ->
            conn
            |> put_resp_header("retry-after", "60")
            |> send_resp(429, "rate limit exceeded")
        end
      end

  A background job calls the same function (see `MyApp.ReportWorker` below).
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @type user_id :: term()

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_path` - path of the limits file. Defaults to the `:rate_limits_path`
      application setting of `:my_app`, read at start.
    * `:default_limit` - requests per minute for users absent from the file. Defaults to `60`.
    * `:name` - the process and table name. Defaults to `#{inspect(__MODULE__)}`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's limit.

  A rejected request is removed again, so it does not count against the user, but it can
  briefly count against requests that run at the same instant.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    requests = requests_table(name)
    now = System.monotonic_time(:millisecond)
    row_key = {user_id, now, :erlang.unique_integer([:monotonic])}

    # Insert first, then count: two concurrent callers can never both see room for one slot.
    :ets.insert(requests, {row_key})

    if count_since(requests, user_id, now - @window_ms) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(requests, row_key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    limits_path = Keyword.get_lazy(opts, :limits_path, &configured_limits_path/0)
    default_limit = Keyword.get(opts, :default_limit, 60)

    limits = load_limits!(limits_path)

    :ets.new(limits_table(name), [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(limits_table(name), [{:default, default_limit} | Map.to_list(limits)])

    :ets.new(requests_table(name), [
      :named_table,
      :public,
      :ordered_set,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    expired = [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}]
    :ets.select_delete(requests_table(name), expired)

    schedule_sweep()
    {:noreply, name}
  end

  defp configured_limits_path, do: Application.fetch_env!(:my_app, :rate_limits_path)

  defp load_limits!(path) do
    {limits, _binding} = Code.eval_file(path)
    true = is_map(limits)
    limits
  end

  defp limit_for(name, user_id) do
    table = limits_table(name)

    case :ets.lookup(table, user_id) do
      [{^user_id, limit}] -> limit
      [] -> :ets.lookup_element(table, :default, 2)
    end
  end

  defp count_since(requests, user_id, cutoff) do
    in_window = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(requests, in_window)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp requests_table(name), do: name
  defp limits_table(name), do: :"#{name}.Limits"
end

defmodule MyApp.ReportWorker do
  @moduledoc """
  Example background-job caller (an Oban-style `perform/1`).
  """

  alias MyApp.RateLimiter

  def perform(%{args: %{"user_id" => user_id}}) do
    case RateLimiter.check(user_id) do
      :ok -> {:ok, build_report(user_id)}
      {:error, :rate_limited} -> {:snooze, 60}
    end
  end

  defp build_report(user_id), do: %{user_id: user_id}
end
