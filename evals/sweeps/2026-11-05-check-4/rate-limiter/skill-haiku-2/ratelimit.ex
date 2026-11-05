defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  Callers ask `check/2` before doing work. When the user is within their limit,
  the request is recorded and `:ok` is returned. When the user has used their
  limit in the last 60 seconds, `{:error, :rate_limited}` is returned and the
  request is not recorded.

  The check runs in the caller's process: it reads and writes one ETS table
  (an in-memory table shared by processes) and does not send a message to the
  limiter, so callers do not queue behind one process.

  ## Configuration

  The limits are read from a JSON file when the limiter starts. `"default"` is
  the limit for every user not listed under `"users"`. The keys under `"users"`
  are user IDs as strings, so the integer `42` is looked up as `"42"`:

      {
        "default": 60,
        "users": {
          "42": 300,
          "7": 10
        }
      }

  Every limit must be a positive integer. A file that cannot be read or parsed,
  or a limit that is not a positive integer, stops the limiter at start, so the
  application fails at boot.

  ## Starting it

  Add it to the supervision tree with the path to the file:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Callers

  A controller action:

      def create(conn, params) do
        user = conn.assigns.current_user

        case MyApp.RateLimiter.check(user.id) do
          :ok ->
            report = MyApp.Reports.generate(user, params)
            json(conn, %{id: report.id})

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  A background job, using the `{:snooze, seconds}` return that Oban uses to
  run the job again later:

      def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> run_export(args)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  # Rows are kept for two windows, not one. A check reads the clock and then
  # counts rows, so the sweep must not delete a row that a check started just
  # before the sweep still needs to count.
  @retention_ms :timer.minutes(2)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter and reads the limits from `:config_path`.

  ## Options

    * `:config_path` - required. Path to the JSON file that holds the limits.
    * `:name` - the registered name, which is also the name of the ETS table.
      Defaults to `MyApp.RateLimiter`. Tests pass their own name.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's
  limit for the last minute.

  Returns `{:error, :rate_limited}` when the limit is used up. A rejected
  request is not counted.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    # Normalise once, so 42 and "42" share one bucket and one limit.
    key = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    limit = limit_for(name, key)
    row = {key, now, System.unique_integer([:monotonic])}
    true = :ets.insert(name, row)

    if count_recent(name, key, now) > limit do
      true = :ets.delete_object(name, row)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    limits = read_limits!(config_path)
    :persistent_term.put({__MODULE__, name}, limits)

    table_options = [
      :named_table,
      :public,
      :duplicate_bag,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    schedule_sweep()

    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @retention_ms
    spec = [{{:_, :"$1", :_}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, spec)
    schedule_sweep()

    {:noreply, name}
  end

  defp limit_for(name, key) do
    limits = :persistent_term.get({__MODULE__, name})

    Map.get(limits.users, key, limits.default)
  end

  defp count_recent(name, key, now) do
    cutoff = now - @window_ms
    spec = [{{key, :"$1", :_}, [{:>, :"$1", cutoff}], [true]}]

    :ets.select_count(name, spec)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp read_limits!(path) do
    case load_limits(path) do
      {:ok, limits} ->
        limits

      {:error, reason} ->
        raise ArgumentError, "bad rate limit file #{path}: #{inspect(reason)}"
    end
  end

  defp load_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_limits(decoded)
    end
  end

  defp parse_limits(%{"default" => default, "users" => users}) when is_map(users) do
    if positive_integer?(default) and Enum.all?(Map.values(users), &positive_integer?/1) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :limits_must_be_positive_integers}
    end
  end

  defp parse_limits(%{"default" => _default, "users" => _users}),
    do: {:error, :users_must_be_a_map}

  defp parse_limits(_decoded), do: {:error, :expected_default_and_users}

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
