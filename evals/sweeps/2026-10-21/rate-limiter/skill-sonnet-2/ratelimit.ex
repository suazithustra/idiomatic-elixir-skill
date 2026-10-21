defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests per rolling minute.

  N comes from a JSON file read once, when the limiter starts:

      {"default_limit": 60, "users": {"42": 600, "43": 10}}

  Users not listed under `"users"` get `default_limit`. User IDs are matched by
  their string form, so `42` and `"42"` use the same limit.

  Each allowed request is stored as one row in an ETS (Erlang Term Storage) table.
  Callers read and write the table from their own processes, so the owning
  GenServer is not a bottleneck. A periodic sweep deletes rows older than a minute.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint
  and any job runner that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  with `config :my_app, rate_limits_path: "priv/rate_limits.json"` in
  `config/runtime.exs`.

  ## Calling it from a controller

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            # ...do the work
          {:error, {:rate_limited, retry_after_ms}} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
            |> send_resp(429, "Too many requests")
        end
      end

  ## Calling it from a background job

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to `#{inspect(__MODULE__)}`.
    * `:sweep_interval` - milliseconds between sweeps of expired rows. Defaults to one minute.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @default_sweep_interval :timer.minutes(1)

  @type user_id :: term()
  @type check_result :: :ok | {:error, {:rate_limited, retry_after_ms :: pos_integer()}}

  @doc """
  Starts the limiter, reading the limits file named by `:config_path`.

  Fails to start if the file is missing or malformed.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [
        :config_path,
        name: __MODULE__,
        sweep_interval: @default_sweep_interval
      ])

    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Records a request by `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed, or
  `{:error, {:rate_limited, retry_after_ms}}` when the user already made their
  limit of requests in the last minute. Rejected requests are not counted.
  """
  @spec check(atom(), user_id()) :: check_result()
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    row = {{user_id, now, System.unique_integer([:monotonic])}}

    # Insert first and count afterwards: a lookup-then-insert would let
    # concurrent requests all see room and exceed the limit.
    true = :ets.insert(name, row)

    if count_since(name, user_id, now - @window_ms) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete_object(name, row)
      {:error, {:rate_limited, retry_after(name, user_id, now)}}
    end
  end

  @doc """
  Returns the limit that applies to `user_id`.
  """
  @spec limit_for(atom(), user_id()) :: pos_integer()
  def limit_for(name \\ __MODULE__, user_id) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, to_string(user_id), default)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, limits} <- load_limits(Keyword.fetch!(opts, :config_path)) do
      :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
      :persistent_term.put({__MODULE__, name}, limits)

      sweep_interval = Keyword.fetch!(opts, :sweep_interval)
      schedule_sweep(sweep_interval)
      {:ok, %{name: name, sweep_interval: sweep_interval}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, %{name: name, sweep_interval: sweep_interval} = state) do
    sweep(name, System.monotonic_time(:millisecond) - @window_ms)
    schedule_sweep(sweep_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase({__MODULE__, name})
  end

  defp count_since(name, user_id, cutoff) do
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp retry_after(name, user_id, now) do
    oldest =
      name
      |> :ets.select([{{{user_id, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}])
      |> Enum.min()

    max(oldest + @window_ms - now, 1)
  end

  defp sweep(name, cutoff) do
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep(interval), do: Process.send_after(self(), :sweep, interval)

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
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

  defp parse_limits(%{"default_limit" => default} = decoded)
       when is_integer(default) and default > 0 do
    with {:ok, users} <- parse_user_limits(Map.get(decoded, "users", %{})) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_decoded), do: {:error, {:invalid_field, "default_limit"}}

  defp parse_user_limits(users) when is_map(users) do
    case Enum.find(users, fn {_user_id, limit} -> not (is_integer(limit) and limit > 0) end) do
      nil -> {:ok, users}
      {user_id, _limit} -> {:error, {:invalid_user_limit, user_id}}
    end
  end

  defp parse_user_limits(_users), do: {:error, {:invalid_field, "users"}}
end
