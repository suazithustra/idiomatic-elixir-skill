defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute.

  N comes from a JSON file that is read once, when the limiter starts:

      {
        "default_limit": 60,
        "users": {"42": 600, "73": 10}
      }

  Users not listed under `"users"` get `"default_limit"`. Every limit must be
  a positive integer. If the file is missing or invalid, the limiter does not
  start.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job processor that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  ## Calling it from a controller

  A plug in the controller turns a refused check into a 429 response:

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

      # in a controller
      plug MyAppWeb.RateLimitPlug

  ## Calling it from a background job

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end

  ## How it works

  Each call to `check/2` inserts one row for the request into a public ETS
  (Erlang Term Storage) table, counts the user's rows from the last minute,
  and deletes its own row if the count is over the limit. Callers do this in
  their own processes, so the owning process is not a bottleneck, and the
  limit is never exceeded. Two requests that arrive at the same instant just
  below the limit may both be refused, because each sees the other's row.
  The owning process only creates the table and sweeps expired rows.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  defguardp is_limit(limit) when is_integer(limit) and limit > 0

  @type user_id :: String.Chars.t()

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - name of the process and its ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {config_path, opts} = Keyword.pop!(opts, :config_path)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the request is within the user's limit. Otherwise returns
  `{:error, {:rate_limited, retry_after_ms}}`, where `retry_after_ms` is the
  time until the user's oldest request in the window expires. A refused request
  does not count against the user.
  """
  @spec check(user_id(), atom()) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(user_id, name \\ __MODULE__) do
    user = to_string(user_id)
    now = now_ms()
    key = {user, now, :erlang.unique_integer([:monotonic])}

    true = :ets.insert(name, {key})

    if count_since(name, user, now - @window_ms) <= limit_for(name, user) do
      :ok
    else
      :ets.delete(name, key)
      {:error, {:rate_limited, retry_after(name, user, now)}}
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_config(config_path) do
      {:ok, config} ->
        :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
        :persistent_term.put({__MODULE__, name}, config)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = now_ms() - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp limit_for(name, user) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user, default)
  end

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp retry_after(name, user, now) do
    spec = [{{{user, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]

    case :ets.select(name, spec, 1) do
      {[oldest], _continuation} -> max(oldest + @window_ms - now, 0)
      :"$end_of_table" -> 0
    end
  end

  defp load_config(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_config(decoded)
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
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_config(%{"default_limit" => default, "users" => users})
       when is_limit(default) and is_map(users) do
    case Enum.find(users, fn {_user, limit} -> not is_limit(limit) end) do
      nil -> {:ok, %{default: default, users: users}}
      {user, limit} -> {:error, {:invalid_limit, user, limit}}
    end
  end

  defp parse_config(_decoded), do: {:error, :invalid_config}
end
