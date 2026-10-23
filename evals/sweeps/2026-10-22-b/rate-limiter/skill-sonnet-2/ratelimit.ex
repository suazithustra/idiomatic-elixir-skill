defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute.

  Limits are read once, when the limiter starts, from a file of Erlang terms,
  one `{user_id, limit}.` tuple per line:

      {1, 120}.
      {"service-account", 600}.

  Users missing from the file get the `:default_limit`.

  The limiter is an ETS table owned by a GenServer. Callers check it from their
  own processes, so checks never queue behind each other. The owner only
  creates the table and sweeps expired entries.

  ## Starting

  Add it to the application's supervision tree, before the endpoint and before
  anything that calls it. The file path is read at runtime:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         limits_path: Application.fetch_env!(:my_app, :rate_limits_path),
         default_limit: 60},
        MyAppWeb.Endpoint
      ]

  ## Examples

  A controller action:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.generate(params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  A background job:

      def perform(%{"user_id" => user_id}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Mailer.send_digest(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_path` - path to the file of `{user_id, limit}.` terms. Required.
    * `:default_limit` - limit for users not in the file. Required.
    * `:name` - process and table name. Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, :default_limit, name: __MODULE__])
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's
  limit for the last minute, or `{:error, :rate_limited}` if it is not.

  Rejected requests are not counted against the user.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    limit = limit_for(name, user_id)
    now = System.monotonic_time(:millisecond)
    key = {:request, user_id, now, :erlang.unique_integer([:monotonic])}

    # Insert first, then count: two concurrent requests can never both read a
    # stale count and slip past the limit.
    :ets.insert(name, {key})

    if count_since(name, user_id, now - @window_ms) <= limit do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp count_since(name, user_id, cutoff) do
    :ets.select_count(name, [
      {{{:request, user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}
    ])
  end

  @impl true
  def init(opts) do
    table = opts[:name]

    case load_limits(Keyword.fetch!(opts, :limits_path)) do
      {:ok, limits} ->
        create_table(table, Keyword.fetch!(opts, :default_limit), limits)
        schedule_sweep()
        {:ok, table}

      {:error, reason} ->
        {:stop, {:invalid_limits_file, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, table) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms

    :ets.select_delete(table, [
      {{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}
    ])

    schedule_sweep()
    {:noreply, table}
  end

  defp create_table(table, default_limit, limits) do
    :ets.new(table, [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(table, {:default_limit, default_limit})
    :ets.insert(table, Enum.map(limits, fn {user_id, limit} -> {{:limit, user_id}, limit} end))
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_limits(path) do
    with {:ok, terms} <- consult(path),
         :ok <- validate_limits(terms) do
      {:ok, terms}
    end
  end

  defp consult(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} -> {:ok, terms}
      {:error, reason} -> {:error, {path, reason}}
    end
  end

  defp validate_limits(terms) do
    case Enum.find(terms, &(not valid_entry?(&1))) do
      nil -> :ok
      entry -> {:error, {:bad_entry, entry}}
    end
  end

  defp valid_entry?({_user_id, limit}), do: is_integer(limit) and limit > 0
  defp valid_entry?(_entry), do: false
end
