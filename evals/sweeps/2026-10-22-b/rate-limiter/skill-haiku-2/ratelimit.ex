defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  The limit for each user comes from a JSON file read when the limiter starts:

      {"default": 60, "users": {"42": 300}}

  `"default"` applies to every user not listed under `"users"`. Keys under
  `"users"` are user IDs as strings. `check/2` converts its argument with
  `to_string/1`, so integer IDs match too.

  ## Starting

  Add the limiter to the supervision tree with the path to the file:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_config)},
        MyAppWeb.Endpoint
      ]

  Starting fails with `{:error, reason}` if the file is missing or invalid.

  ## Callers

  Call `check/1` before doing the work. Checks do not go through the process:
  callers read and write a public ETS table, so they do not queue behind one
  another.

  A controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok -> do_create(conn, params)
          {:error, :rate_limited} -> send_resp(conn, 429, "Too many requests")
        end
      end

  A background job, which returns an error so the queue retries it later:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> send_digest(user_id)
          {:error, :rate_limited} -> {:error, :rate_limited}
        end
      end

  ## How it works

  Each allowed request is one row in an ordered ETS table, keyed by user,
  timestamp, and a unique integer. A check inserts its own row, counts the
  user's rows from the last minute, and deletes its row again if the count is
  over the limit. The row is inserted before the count, so two concurrent
  checks cannot both read a stale count and both pass. A check can be denied a
  moment early when a concurrent request's row is still present, but no more
  than the limit is ever allowed.

  The owning process sweeps rows older than the window, so memory stays bounded.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(30)

  @doc """
  Starts the limiter and reads the limits file at `:config_path`.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the process name and the ETS table name. Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and reports whether it is within the user's limit.

  Returns `:ok` for an allowed request, or `{:error, :rate_limited}` when the user
  has already made their limit of requests in the last minute. Denied requests
  are not counted.
  """
  @spec check(term()) :: :ok | {:error, :rate_limited}
  @spec check(GenServer.name(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    key = to_string(user_id)
    limit = limit_for(name, key)
    now = System.monotonic_time(:millisecond)
    entry = {key, now, System.unique_integer([:monotonic])}

    :ets.insert(name, {entry})

    if count_recent(name, key, now) > limit do
      :ets.delete(name, entry)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_config(config_path) do
      {:ok, config} ->
        :persistent_term.put({__MODULE__, name}, config)

        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp limit_for(name, key) do
    %{default: default, limits: limits} = :persistent_term.get({__MODULE__, name})
    Map.get(limits, key, default)
  end

  defp count_recent(name, key, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{key, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
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
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_config(%{"default" => default, "users" => users})
       when is_integer(default) and default > 0 and is_map(users) do
    if Enum.all?(users, fn {_user, limit} -> is_integer(limit) and limit > 0 end) do
      {:ok, %{default: default, limits: users}}
    else
      {:error, :invalid_user_limit}
    end
  end

  defp parse_config(other), do: {:error, {:invalid_config, other}}
end
