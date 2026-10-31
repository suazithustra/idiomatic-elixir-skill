defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make a limited number of requests in any
  rolling minute.

  Limits come from a JSON file read once when the limiter starts:

      {"default": 60, "users": {"42": 600, "1001": 10}}

  A user not listed under `"users"` gets `"default"`. User ids are matched by
  their string form, so `42` and `"42"` are the same user.

  Every request is stored as a row in an ETS (Erlang Term Storage) table. Callers
  write and count rows in their own processes, so the limiter process is not a
  bottleneck. Two requests that arrive at the same instant while a user is one
  below the limit may both be refused; the limit is never exceeded.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and any job
  runner, so no caller can reach it before it exists:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, path: "priv/rate_limits.json"},
        MyAppWeb.Endpoint
      ]

  Without `:path`, the limiter reads `config :my_app, MyApp.RateLimiter, path: ...`
  at startup. If the file is missing or invalid, the limiter fails to start and
  so does the application.

  ## Calling it

  A controller:

      def create(conn, params) do
        with :ok <- MyApp.RateLimiter.check(conn.assigns.current_user.id),
             {:ok, report} <- Reports.create(params) do
          json(conn, report)
        else
          {:error, {:rate_limited, retry_after_ms}} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
            |> send_resp(429, "rate limit exceeded")

          {:error, changeset} ->
            conn
            |> put_status(422)
            |> json(%{errors: changeset})
        end
      end

  A background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> Exports.run(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: term()

  @doc """
  Starts the limiter and its ETS table.

  ## Options

    * `:path` - the limits file. Defaults to the `:path` set in the application
      config for this module.
    * `:name` - an atom naming the process and its table. Defaults to
      `#{inspect(__MODULE__)}`.
    * `:sweep_interval` - milliseconds between removals of expired requests.
      Defaults to one minute.
  """
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:path, name: __MODULE__, sweep_interval: @sweep_interval_ms])
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok`, or `{:error, {:rate_limited, retry_after_ms}}` when the user
  already made their limit of requests in the last minute. A refused request is
  not counted.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    hit = {:hit, user, now, :erlang.unique_integer([:monotonic])}

    true = :ets.insert(name, {hit})

    if count_hits(name, user, now) <= limit_for(name, user) do
      :ok
    else
      :ets.delete(name, hit)
      {:error, {:rate_limited, retry_after(name, user, now)}}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, path} <- fetch_path(opts),
         {:ok, limits} <- load_limits(path) do
      :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
      :ets.insert(name, limits)
      schedule_sweep(opts[:sweep_interval])
      {:ok, %{name: name, sweep_interval: opts[:sweep_interval]}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    expired_before = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:hit, :_, :"$1", :_}}, [{:"=<", :"$1", expired_before}], [true]}]

    :ets.select_delete(state.name, match_spec)
    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  defp count_hits(name, user, now) do
    match_spec = [{{{:hit, user, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{{:limit, ^user}, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp retry_after(name, user, now) do
    match_spec = [{{{:hit, user, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]
    oldest = Enum.min(:ets.select(name, match_spec))
    max(oldest + @window_ms - now, 1)
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp fetch_path(opts) do
    case opts[:path] || config()[:path] do
      nil -> {:error, :missing_limits_path}
      path -> {:ok, path}
    end
  end

  defp config do
    Application.get_env(:my_app, __MODULE__, [])
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
      {:error, reason} -> {:error, {:unreadable_limits_file, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_limits_json, reason}}
    end
  end

  # Returns the rows to store: the default limit and one row per listed user.
  defp parse_limits(%{"default" => default} = decoded) when is_integer(default) and default > 0 do
    users = Map.get(decoded, "users", %{})

    if is_map(users) and Enum.all?(users, &valid_user_limit?/1) do
      {:ok, [{:default_limit, default} | Enum.map(users, &user_limit_row/1)]}
    else
      {:error, {:invalid_limits, "users"}}
    end
  end

  defp parse_limits(_decoded), do: {:error, {:invalid_limits, "default"}}

  defp valid_user_limit?({_user, limit}), do: is_integer(limit) and limit > 0

  defp user_limit_row({user, limit}), do: {{:limit, user}, limit}
end
