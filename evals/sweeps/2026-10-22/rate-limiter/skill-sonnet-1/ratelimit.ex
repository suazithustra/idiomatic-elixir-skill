defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute.

  Every request is stored as a row in a public ETS (Erlang Term Storage) table,
  so callers in controllers and background jobs check the limit from their own
  process and never queue behind one another. The owning GenServer only creates
  the table, reads the limits file, and sweeps expired rows.

  ## Limits file

  A JSON file read once when the limiter starts. `"default"` applies to users
  not listed under `"users"`:

      {"default": 60, "users": {"42": 600, "7": 10}}

  User ids are compared as strings, so `42` and `"42"` are the same user.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and any job
  processor, so it is running when they take their first request:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: "priv/rate_limits.json"},
        MyAppWeb.Endpoint
      ]

  Without `:config_path`, the path is read at startup from
  `config :my_app, MyApp.RateLimiter, config_path: "..."`, which can be set in
  `config/runtime.exs`.

  ## Calling it

  In a controller, as a plug:

      defmodule MyAppWeb.RateLimitPlug do
        import Plug.Conn

        def init(opts), do: opts

        def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) do
          case MyApp.RateLimiter.check(user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  In a background job:

      defmodule MyApp.Workers.ExportWorker do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Exports.run(user_id)
            {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
          end
        end
      end

  ## Options

    * `:config_path` - path of the limits file. Required unless set in the
      application environment as described above.
    * `:name` - name of the process and of its ETS table. Defaults to
      `#{inspect(__MODULE__)}`. Must be an atom.
    * `:sweep_interval` - milliseconds between sweeps of expired rows.
      Defaults to one minute.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @default_sweep_interval :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's
  limit, or `{:error, {:rate_limited, retry_after_ms}}` if not. A rejected
  request is not counted.

  Under heavy concurrency for the same user, simultaneous requests that would
  push the count over the limit may all be rejected, so the limiter errs on the
  side of letting fewer requests through, never more.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    row = {user, now, :erlang.unique_integer()}

    # Insert first, then count: the insert is atomic, so two concurrent callers
    # both see each other's rows and cannot both slip under the limit.
    :ets.insert(name, row)

    if count_since(name, user, now - @window_ms) <= limit_for(name, user) do
      :ok
    else
      :ets.delete_object(name, row)
      {:error, {:rate_limited, retry_after(name, user, now)}}
    end
  end

  @doc """
  Returns the number of requests `user_id` has made in the last minute.
  """
  @spec count(atom(), user_id()) :: non_neg_integer()
  def count(name \\ __MODULE__, user_id) do
    count_since(name, to_string(user_id), System.monotonic_time(:millisecond) - @window_ms)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, path} <- fetch_config_path(opts),
         {:ok, limits} <- load_limits(path) do
      :ets.new(name, [
        :named_table,
        :public,
        :bag,
        read_concurrency: true,
        write_concurrency: true
      ])

      :persistent_term.put({__MODULE__, name}, limits)

      sweep_interval = Keyword.get(opts, :sweep_interval, @default_sweep_interval)
      schedule_sweep(sweep_interval)
      {:ok, %{name: name, sweep_interval: sweep_interval}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, %{name: name, sweep_interval: sweep_interval} = state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{:_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep(sweep_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase({__MODULE__, name})
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [{{user, :"$1", :_}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user, default)
  end

  defp retry_after(name, user, now) do
    oldest =
      :ets.select(name, [{{user, :"$1", :_}, [{:>, :"$1", now - @window_ms}], [:"$1"]}])
      |> Enum.min()

    max(oldest + @window_ms - now, 1)
  end

  defp fetch_config_path(opts) do
    case Keyword.fetch(opts, :config_path) do
      {:ok, path} -> {:ok, path}
      :error -> app_env_config_path()
    end
  end

  defp app_env_config_path do
    case :my_app |> Application.get_env(__MODULE__, []) |> Keyword.fetch(:config_path) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, :missing_config_path}
    end
  end

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_config_json}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) when is_integer(default) and default > 0 do
    with {:ok, users} <- parse_user_limits(Map.get(decoded, "users", %{})) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_decoded), do: {:error, {:invalid_config, "default"}}

  defp parse_user_limits(users) when is_map(users) do
    if Enum.all?(users, fn {_user, limit} -> is_integer(limit) and limit > 0 end) do
      {:ok, users}
    else
      {:error, {:invalid_config, "users"}}
    end
  end

  defp parse_user_limits(_users), do: {:error, {:invalid_config, "users"}}
end
