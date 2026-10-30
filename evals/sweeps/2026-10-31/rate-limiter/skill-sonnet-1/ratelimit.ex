defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute, where N comes from a JSON file read when the limiter starts.

  Callers check the limit from their own process. The limiter process only owns
  the ETS (Erlang Term Storage) table and sweeps expired entries, so checks do
  not queue behind one another.

  ## Config file

      {
        "default": 60,
        "users": {"42": 300, "1001": 10}
      }

  `default` applies to every user not listed under `users`. User ids are
  compared as strings, so `42` and `"42"` are the same user.

  ## Starting it

  Pass the path from runtime config, so `config/runtime.exs` decides it:

      # config/runtime.exs
      config :my_app, MyApp.RateLimiter, config_path: System.fetch_env!("RATE_LIMITS_PATH")

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, Application.fetch_env!(:my_app, MyApp.RateLimiter)},
        MyAppWeb.Endpoint
      ]

  Start it before anything that calls it. Tests can start a private instance with
  `start_supervised!({MyApp.RateLimiter, name: :limiter_test, config_path: path})`
  and pass that name as the first argument of `check/2`.

  ## Calling it from a controller

      defmodule MyAppWeb.Plugs.RateLimit do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              retry_after = Integer.to_string(div(retry_after_ms, 1000) + 1)

              conn
              |> put_resp_header("retry-after", retry_after)
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

      # in a controller
      plug MyAppWeb.Plugs.RateLimit when action in [:create, :update]

  ## Calling it from a background job

      defmodule MyApp.Workers.SendDigest do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Digests.send(user_id)
            {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - registered name, also the name of the ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is within the user's limit.

  Returns `:ok` when the request is allowed. Returns
  `{:error, {:rate_limited, retry_after_ms}}` when the user already made their
  limit of requests in the last minute; `retry_after_ms` is how long until the
  oldest of those requests leaves the window. A rejected request is not counted.
  """
  @spec check(GenServer.name(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    request_key = {user, now, :erlang.unique_integer([:monotonic])}

    # Insert first and count after: the insert is atomic, so concurrent
    # requests cannot both read an old count and slip past the limit.
    # Two simultaneous requests at the limit may both be rejected; the limit is
    # never exceeded.
    :ets.insert(name, {request_key})

    if count_since(name, user, now - @window_ms) <= limit_for(name, user) do
      :ok
    else
      reject(name, request_key, now)
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        table_options = [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ]

        :ets.new(name, table_options)
        :ets.insert(name, limit_rows(limits))
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, config_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp reject(name, {user, _at, _unique} = request_key, now) do
    oldest = Enum.min(timestamps_since(name, user, now - @window_ms))
    :ets.delete(name, request_key)
    {:error, {:rate_limited, max(oldest + @window_ms - now, 1)}}
  end

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp timestamps_since(name, user, cutoff) do
    :ets.select(name, [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [:"$1"]}])
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default, 2)
    end
  end

  defp limit_rows(%{default: default, users: users}) do
    user_rows = Enum.map(users, fn {user, limit} -> {{:limit, user}, limit} end)
    [{:default, default} | user_rows]
  end

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      validate_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, {:unreadable, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp validate_limits(%{"default" => default, "users" => users})
       when is_map(users) and is_integer(default) and default > 0 do
    if Enum.all?(users, fn {_user, limit} -> is_integer(limit) and limit > 0 end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_user_limit}
    end
  end

  defp validate_limits(_decoded), do: {:error, :invalid_shape}
end
