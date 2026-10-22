defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in a rolling one-minute window.

  Callers check the limit in their own process with `check/2`, so checks for
  different users never queue behind each other. The GenServer owns the ETS
  table that holds the limits and the recent requests. It reads the limits
  from a JSON file when it starts and removes expired requests once a minute.

  The config file looks like this:

      {
        "default": 60,
        "users": {"42": 300, "7": 0}
      }

  `default` applies to every user not listed under `users`. User IDs are
  compared as strings, so the integer `42` and the string `"42"` are the same
  user. The file is read only when the limiter starts.

  ## Starting

      children = [
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Callers

  A plug rejects the request before it reaches the controller action:

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
              |> send_resp(:too_many_requests, "rate limit exceeded")
              |> halt()
          end
        end
      end

  A background job checks the limit before its work. An Oban worker reschedules
  itself when the user is over the limit:

      def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(args)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval @window_ms
  @table_options [:named_table, :ordered_set, :public, read_concurrency: true]

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the registered name, which is also the name of the ETS table.
      Defaults to `MyApp.RateLimiter`. Tests pass their own name so they can
      run their own instance.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records one request for `user_id`.

  Returns `:ok` when the request is within the user's limit. Returns
  `{:error, :rate_limited}` when it is over the limit; a rejected request is
  not counted.

  The count is taken in the calling process with ETS operations that are each
  atomic. The request's row is inserted before the count and removed again if
  the count is over the limit, so two concurrent requests cannot both pass
  when only one slot is left.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    id = to_string(user_id)
    now = now()
    key = {id, now, System.unique_integer([:positive])}
    limit = limit_for(name, id)

    :ets.insert(name, {key, true})

    if count_recent(name, id, now) > limit do
      :ets.delete(name, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.fetch!(opts, :config_path)

    case read_config(path) do
      {:ok, config} ->
        :ets.new(name, @table_options)
        :ets.insert(name, limit_rows(config))
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    expire_before(name, now() - @window_ms)
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp limit_for(name, id) do
    case :ets.lookup(name, {:limit, id}) do
      [{_key, limit}] -> limit
      [] -> default_limit(name)
    end
  end

  defp default_limit(name) do
    [{:default_limit, limit}] = :ets.lookup(name, :default_limit)
    limit
  end

  defp count_recent(name, id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{id, :"$1", :_}, :_}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp expire_before(name, cutoff) do
    :ets.select_delete(name, [{{{:_, :"$1", :_}, :_}, [{:"=<", :"$1", cutoff}], [true]}])
  end

  defp limit_rows(%{default: default, users: users}) do
    user_rows = Enum.map(users, fn {id, limit} -> {{:limit, id}, limit} end)
    [{:default_limit, default} | user_rows]
  end

  defp read_config(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_config(decoded)
    end
  end

  defp parse_config(%{"default" => default, "users" => users})
       when is_integer(default) and default >= 0 and is_map(users) do
    if Enum.all?(users, fn {_id, limit} -> is_integer(limit) and limit >= 0 end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_config}
    end
  end

  defp parse_config(_other), do: {:error, :invalid_config}
end
