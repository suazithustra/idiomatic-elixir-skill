defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N comes from a file read once, when the limiter starts. The file holds one Erlang
  term, a list of `{user_id, limit}` tuples, ended by a period:

      [{1, 120}, {2, 10}, {<<"service-account">>, 600}].

  Users missing from the file get the `:default_limit` option. User IDs should be
  integers or binaries.

  Every request is stored as one row in a public ETS (Erlang Term Storage) table, so
  callers check the limit in their own process and never queue behind a single
  process. The owning GenServer only creates the table, loads the limits, and sweeps
  expired rows.

  ## Starting

  Add it to the supervision tree before the endpoint and before any job runner:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.fetch_env!(:my_app, :rate_limit_file), default_limit: 60},
        MyAppWeb.Endpoint
      ]

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

  ## Calling it from a background job

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: integer() | binary()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path of the limits file. Required.
    * `:default_limit` - requests per minute for users not in the file. Defaults to `60`.
    * `:name` - registered name, also the name of the ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, :name, default_limit: 60])
    name = Keyword.get(opts, :name, __MODULE__)

    init_arg = %{
      name: name,
      config_path: Keyword.fetch!(opts, :config_path),
      default_limit: opts[:default_limit]
    }

    GenServer.start_link(__MODULE__, init_arg, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  A refused request is not counted against the user.

  Needs a running limiter, so there is no doctest. A caller looks like
  `:ok = MyApp.RateLimiter.check(42)`.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    hit = {user_id, now, System.unique_integer([:monotonic])}

    # Insert first, then count: a read-then-write would let concurrent callers
    # all see room and all pass. Under contention this can refuse a request
    # that would have fit, never admit one over the limit.
    :ets.insert(name, {hit})

    if count_since(name, user_id, now - @window_ms) <= limit(name, user_id) do
      :ok
    else
      :ets.delete(name, hit)
      {:error, :rate_limited}
    end
  end

  @doc """
  Returns the number of requests per minute allowed for `user_id`.
  """
  @spec limit(atom(), user_id()) :: pos_integer()
  def limit(name \\ __MODULE__, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  @impl true
  def init(%{name: name} = init_arg) do
    with {:ok, limits} <- read_limits(init_arg.config_path) do
      table_options = [
        :named_table,
        :public,
        :ordered_set,
        read_concurrency: true,
        write_concurrency: true
      ]

      :ets.new(name, table_options)
      :ets.insert(name, {:default_limit, init_arg.default_limit})
      :ets.insert(name, Enum.map(limits, fn {user_id, limit} -> {{:limit, user_id}, limit} end))

      schedule_sweep()
      {:ok, name}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])

    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp read_limits(path) do
    with {:ok, terms} <- consult(path),
         {:ok, limits} <- validate_limits(terms) do
      {:ok, limits}
    else
      {:error, reason} -> {:stop, {:invalid_rate_limit_file, path, reason}}
    end
  end

  defp consult(path) do
    case :file.consult(path) do
      {:ok, [limits]} -> {:ok, limits}
      {:ok, terms} -> {:error, {:expected_one_term, length(terms)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_limits(limits) when is_list(limits) do
    if Enum.all?(limits, &valid_entry?/1) do
      {:ok, limits}
    else
      {:error, :bad_entry}
    end
  end

  defp validate_limits(_other), do: {:error, :not_a_list}

  defp valid_entry?({user_id, limit}) do
    (is_integer(user_id) or is_binary(user_id)) and is_integer(limit) and limit > 0
  end

  defp valid_entry?(_other), do: false
end
