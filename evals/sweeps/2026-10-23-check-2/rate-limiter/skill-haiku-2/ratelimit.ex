defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling 60-second window.

  Limits come from a JSON file that is read once, when the limiter starts:

      {"default": 60, "users": {"42": 300, "17": 10}}

  `"default"` applies to every user not listed under `"users"`. The file keys
  users by string, so an integer user ID is matched by its string form.

  ## Starting

  Add the limiter to the application's supervision tree:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_file: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint
      ]

  ## Checking

  Call `check/1` before doing the work. It returns `:ok` and counts the request,
  or `{:error, :rate_limited}` and leaves no record of it.

  A controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            do_create(conn, params)

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  A background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> export(job.args)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms :timer.seconds(10)

  @doc """
  Counts one request for `user_id` if the user is under their limit.

  Returns `:ok`, or `{:error, :rate_limited}` when the user has already made
  their limit of requests in the last 60 seconds. `name` is the limiter's name,
  `MyApp.RateLimiter` by default.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user_key = to_string(user_id)
    limit = limit_for(name, user_key)
    now = System.monotonic_time(:millisecond)
    row = {user_key, :erlang.unique_integer([:monotonic, :positive])}

    # Insert before counting. Two requests that count at the same moment each
    # see the other's row, so they cannot both pass a count read before writing.
    :ets.insert(name, {row, now})

    if count_in_window(name, user_key, now) <= limit do
      :ok
    else
      :ets.delete(name, row)
      {:error, :rate_limited}
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_file, name: __MODULE__])
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    case load_limits(Keyword.fetch!(opts, :config_file)) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, limits)

        table_options = [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ]

        :ets.new(name, table_options)
        schedule_sweep()
        {:ok, %{table: name}}

      {:error, reason} ->
        {:stop, {:rate_limit_config, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, %{table: table} = state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms

    # Rows older than the window no longer count, so deleting them only keeps
    # the table from growing.
    :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp limit_for(name, user_key) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, user_key, limits.default)
  end

  defp count_in_window(name, user_key, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user_key, :_}, :"$1"}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp load_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_limits(decoded)
    end
  end

  defp parse_limits(%{"default" => default, "users" => users}) when is_map(users) do
    if valid_limit?(default) and Enum.all?(Map.values(users), &valid_limit?/1) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_config}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_config}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
