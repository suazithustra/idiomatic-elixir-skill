defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N comes from a JSON file read once, when the limiter starts:

      {
        "default": 60,
        "users": {"42": 600, "1001": 10}
      }

  `"default"` applies to every user not listed under `"users"`. User ids are
  compared as strings, so `42` and `"42"` are the same user. If the file is
  missing or invalid, the limiter does not start and the supervisor reports why.

  Each request is stored as one row in a public ETS (Erlang Term Storage) table
  owned by this process. Callers insert and count in their own processes, so the
  GenServer is not a bottleneck. A call inserts its row first and then counts, so
  two concurrent calls can never both be admitted past the limit. Under a burst
  at the limit, both may be rejected, which errs on the side of the limit.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint and
  any job processor that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  and set the path in `config/runtime.exs`:

      config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

  ## Calling it from a controller

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            # do the work
            json(conn, MyApp.Reports.create(params))

          {:error, {:rate_limited, retry_after_ms}} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
            |> send_resp(429, "Too many requests")
        end
      end

  ## Calling it from a background job (Oban worker)

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Reports.generate(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)

  defguardp is_limit(value) when is_integer(value) and value >= 0

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:path` - path to the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to
      `MyApp.RateLimiter`. Pass another name to run a second instance, for
      example in a test.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.fetch!(opts, :path)

    GenServer.start_link(__MODULE__, {name, path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is within the user's limit.

  Returns `:ok` when the request is allowed. Otherwise returns
  `{:error, {:rate_limited, retry_after_ms}}`, where `retry_after_ms` is how
  long until the user's oldest request in the window expires. A rejected
  request is not counted against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, non_neg_integer()}}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    hit = {user, now, System.unique_integer([:monotonic])}

    :ets.insert(name, {hit})

    if count_hits(name, user, now - @window_ms) <= limit_for(name, user) do
      :ok
    else
      :ets.delete(name, hit)
      {:error, {:rate_limited, retry_after(name, user, now)}}
    end
  end

  @impl true
  def init({name, path}) do
    case load_limits(path) do
      {:ok, limits} ->
        create_table(name, limits)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    expired = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]

    :ets.select_delete(name, expired)
    schedule_sweep()
    {:noreply, name}
  end

  # One ordered table holds both kinds of row, told apart by key shape. A request
  # is `{{user, timestamp, unique}}`; limits are `{{:limit, user}, n}` and
  # `{:default_limit, n}`. The match specs below only match the 3-tuple keys.
  defp create_table(name, limits) do
    :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])

    user_rows = for {user, limit} <- limits.users, do: {{:limit, user}, limit}
    :ets.insert(name, [{:default_limit, limits.default} | user_rows])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  defp count_hits(name, user, cutoff) do
    recent = [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, recent)
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp retry_after(name, user, now) do
    recent = [{{{user, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]
    oldest = Enum.min(:ets.select(name, recent), &<=/2, fn -> now end)

    oldest + @window_ms - now
  end

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error, {:unreadable_limits_file, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, {:invalid_limits_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) when is_limit(default) do
    users = Map.get(decoded, "users", %{})

    case Enum.find(users, fn {_user, limit} -> not is_limit(limit) end) do
      nil -> {:ok, %{default: default, users: users}}
      {user, _limit} -> {:error, {:invalid_user_limit, user}}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_limits}
end
