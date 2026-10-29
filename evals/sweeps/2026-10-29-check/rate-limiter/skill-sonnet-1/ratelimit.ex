defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: at most N requests per rolling minute.

  N comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"42": 600, "7": 10}}

  A user not listed under `"users"` gets `"default"`. User IDs are the
  file's string keys, so callers pass the ID as a string.

  Each allowed request is one row in an ETS (Erlang Term Storage) table
  owned by this process. `check/2` runs in the caller's process, so
  callers do not queue behind the owner. The owner only creates the
  table, loads the limits, and sweeps expired rows.

  ## Starting

  Add it to the supervision tree before anything that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: "priv/rate_limits.json"},
        MyAppWeb.Endpoint
      ]

  ## Calling

  A Phoenix plug:

      defmodule MyAppWeb.Plugs.RateLimit do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              retry_after = div(retry_after_ms, 1000) + 1

              conn
              |> put_resp_header("retry-after", Integer.to_string(retry_after))
              |> send_resp(429, "rate limit exceeded")
              |> halt()
          end
        end
      end

  A background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t()

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - the process name, also the name of its ETS table.
      Defaults to `#{inspect(__MODULE__)}`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed, or
  `{:error, {:rate_limited, retry_after_ms}}` when the user has used
  all their requests in the last minute. A rejected request is not
  counted. Pass `name` to use a limiter started under another name.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) when is_binary(user_id) do
    now = System.monotonic_time(:millisecond)
    key = {user_id, now, System.unique_integer([:monotonic])}

    # Insert first, then count: two concurrent requests cannot both read
    # the same count and both slip under the limit.
    :ets.insert(name, {key})

    if count_since(name, user_id, now - @window_ms) <= limit(name, user_id) do
      :ok
    else
      :ets.delete(name, key)
      {:error, {:rate_limited, retry_after(name, user_id, now)}}
    end
  end

  @impl true
  def init({name, config_path}) do
    limits_table = limits_table(name)

    :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
    :ets.new(limits_table, [:named_table, :protected, :set, read_concurrency: true])
    :ets.insert(limits_table, load_limits!(config_path))

    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]

    :ets.select_delete(name, match_spec)
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp load_limits!(config_path) do
    %{"default" => default, "users" => users} =
      config_path
      |> File.read!()
      |> JSON.decode!()

    [{:default, default} | Enum.map(users, fn {user_id, limit} -> {user_id, limit} end)]
  end

  defp limit(name, user_id) do
    limits_table = limits_table(name)

    case :ets.lookup(limits_table, user_id) do
      [{^user_id, limit}] -> limit
      [] -> :ets.lookup_element(limits_table, :default, 2)
    end
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]

    :ets.select_count(name, match_spec)
  end

  defp retry_after(name, user_id, now) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]
    oldest = name |> :ets.select(match_spec) |> Enum.min(fn -> now end)

    max(oldest + @window_ms - now, 1)
  end

  defp limits_table(name) do
    :"#{name}_limits"
  end
end
