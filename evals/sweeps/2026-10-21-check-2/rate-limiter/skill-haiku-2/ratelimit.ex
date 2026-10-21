defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling 60-second window.

  N comes from a term file that is read once, when the limiter starts. The file
  holds one `{key, limit}.` term per line. `key` is a user ID (an integer or a
  string), and `default` sets the limit for every user not listed:

      {default, 60}.
      {42, 120}.
      {"svc-backfill", 600}.

  Add the limiter to the supervision tree:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.term")},
        MyAppWeb.Endpoint
      ]

  Call `check/1` before doing the work. A controller:

      def create(conn, _params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            # ... do the work ...

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  A background job:

      def run(user_id) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_export(user_id)
          {:error, :rate_limited} -> {:error, :rate_limited}
        end
      end

  Edits to the config file take effect after the limiter restarts.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(30)

  @doc """
  Starts the limiter.

  Options:

    * `:config_path` - required. Path to the limits term file.
    * `:name` - registered name, and the name of the ETS table it owns.
      Defaults to this module.

  Returns `{:error, reason}` when the file cannot be read or does not
  contain valid limits.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's
  limit.

  Returns `{:error, :rate_limited}` when the user already made their limit of
  requests in the last 60 seconds. A rejected request is not counted.

  Any process can call this. It reads and writes the ETS table directly, so
  callers do not wait on the GenServer.
  """
  @spec check(integer() | String.t(), atom()) :: :ok | {:error, :rate_limited}
  def check(user_id, name \\ __MODULE__) do
    now = System.monotonic_time(:millisecond)
    request = {user_id, now, System.unique_integer([:positive, :monotonic])}

    # Insert before counting. If each request counted before the other inserted,
    # two concurrent requests could both pass. With insert first, the later of
    # two concurrent requests always sees the earlier one.
    :ets.insert(name, {request})

    if count_in_window(name, user_id, now) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, request)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    case load_limits(Keyword.fetch!(opts, :config_path)) do
      {:ok, limits} ->
        # An ordered_set keeps each user's requests next to each other, so counting
        # one user does not scan the whole table.
        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        # Limit keys are 2-tuples, so they never match the 3-tuple request keys.
        :ets.insert(name, Enum.map(limits, fn {user, limit} -> {{:limit, user}, limit} end))
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    # Users who stop calling would otherwise keep their old requests forever.
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp count_in_window(name, user_id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    default = :ets.lookup_element(name, {:limit, :default}, 2)
    :ets.lookup_element(name, {:limit, user_id}, 2, default)
  end

  defp load_limits(path) do
    case :file.consult(path) do
      {:ok, entries} -> validate_limits(entries)
      {:error, reason} -> {:error, {:unreadable_config, reason}}
    end
  end

  defp validate_limits(entries) do
    cond do
      not Enum.all?(entries, &match?({_user, limit} when is_integer(limit) and limit > 0, &1)) ->
        {:error, :invalid_limit}

      not Enum.any?(entries, &match?({:default, _limit}, &1)) ->
        {:error, :missing_default}

      true ->
        {:ok, entries}
    end
  end
end
