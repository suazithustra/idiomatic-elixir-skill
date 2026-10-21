defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make a limited number of requests in any
  rolling 60-second window.

  Limits come from a JSON file read once when the limiter starts. Users not
  listed in the file get the `"default"` limit:

      {
        "default": 60,
        "users": {"42": 600, "1001": 5}
      }

  The limiter process only owns an ETS (Erlang Term Storage) table and sweeps
  old entries. `check/2` runs in the caller's process, so callers do not queue
  behind each other.

  ## Starting it

  Add it to the supervision tree before anything that uses it:

      # lib/my_app/application.ex
      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

      # config/runtime.exs
      config :my_app, :rate_limits_path, System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.create(params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.Export do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Exports.run(user_id)
            {:error, :rate_limited} -> {:snooze, 60}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - registered name, also the name of the ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit, or
  `{:error, :rate_limited}` when they have already used their requests in the
  last minute. Rejected requests do not count against the user.
  """
  @spec check(atom(), String.Chars.t()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    limit = limit_for(name, user)

    # Insert first, then count: a read-then-write would let concurrent
    # requests all see room and all pass.
    hit = {:hit, user, System.monotonic_time(:millisecond), :erlang.unique_integer()}
    :ets.insert(name, {hit})

    if count_hits(name, user) <= limit do
      :ok
    else
      :ets.delete(name, hit)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ets.insert(name, limits)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    :ets.select_delete(name, [
      {{{:hit, :_, :"$1", :_}}, [{:"=<", :"$1", window_start()}], [true]}
    ])

    schedule_sweep()
    {:noreply, name}
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> default_limit(name)
    end
  end

  defp default_limit(name) do
    [{_key, limit}] = :ets.lookup(name, {:limit, :default})
    limit
  end

  defp count_hits(name, user) do
    :ets.select_count(name, [
      {{{:hit, user, :"$1", :_}}, [{:>, :"$1", window_start()}], [true]}
    ])
  end

  defp window_start, do: System.monotonic_time(:millisecond) - @window_ms

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents),
         {:ok, limits} <- parse_limits(decoded) do
      {:ok, limits}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:config_unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:config_invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) do
    users = Map.get(decoded, "users", %{})
    entries = [{:default, default} | Enum.map(users, fn {user, limit} -> {user, limit} end)]

    case Enum.find(entries, fn {_user, limit} -> not (is_integer(limit) and limit >= 0) end) do
      nil -> {:ok, Enum.map(entries, fn {user, limit} -> {{:limit, user}, limit} end)}
      {user, limit} -> {:error, {:config_invalid_limit, user, limit}}
    end
  end

  defp parse_limits(_decoded), do: {:error, {:config_missing_key, "default"}}
end
