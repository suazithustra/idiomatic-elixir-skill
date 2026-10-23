defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling minute.

  Limits come from a JSON file read when the process starts:

      {
        "default": 60,
        "users": {"42": 300, "77": 10}
      }

  A user without an entry under `"users"` gets `"default"`. User IDs are
  compared as strings, so `42` and `"42"` are the same user.

  `check/2` runs in the calling process and touches only ETS, so controllers
  and jobs do not queue behind one process. The GenServer owns the table and
  removes expired requests.

  Add it to the supervision tree:

      children = [
        {MyApp.RateLimiter,
         limits_file: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Callers

  A controller:

      def create(conn, params) do
        user = conn.assigns.current_user

        case MyApp.RateLimiter.check(user.id) do
          :ok -> render_report(conn, Reports.create(user, params))
          {:error, :rate_limited} -> send_resp(conn, 429, "Too many requests")
        end
      end

  A background job, which retries once the window has passed:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> Exports.run(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @doc """
  Starts the limiter and reads the limits file.

  ## Options

    * `:limits_file` - required. Path to the JSON file described in the module docs.
    * `:name` - the process and ETS table name. Defaults to the module name.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    limits_file = Keyword.fetch!(opts, :limits_file)

    GenServer.start_link(__MODULE__, {name, limits_file}, name: name)
  end

  @doc """
  Records a request for `user_id` and returns `:ok` if it is within the limit.

  A request over the limit is not kept, so retrying does not extend the wait.
  """
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    limit = limit_for(name, user)
    now = System.monotonic_time(:millisecond)
    key = {:request, user, System.unique_integer([:monotonic])}

    # Insert before counting: concurrent requests then see each other, so
    # two of them cannot both read a count below the limit and both pass.
    :ets.insert(name, {key, now})

    if count_since(name, user, now - @window) > limit do
      :ets.delete(name, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, limits_file}) do
    case load_limits(limits_file) do
      {:ok, default, users} ->
        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ets.insert(name, {:default_limit, default})
        :ets.insert(name, Enum.map(users, fn {user, limit} -> {{:limit, user}, limit} end))
        schedule_sweep()

        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window

    :ets.select_delete(name, [
      {{{:request, :_, :_}, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}
    ])

    schedule_sweep()
    {:noreply, name}
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [
      {{{:request, user, :_}, :"$1"}, [{:>, :"$1", cutoff}], [true]}
    ])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp load_limits(path) do
    case File.read(path) do
      {:ok, contents} -> parse_limits(contents)
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp parse_limits(contents) do
    case Jason.decode(contents) do
      {:ok, %{"default" => default, "users" => users}} ->
        if valid_limits?(default, users) do
          {:ok, default, users}
        else
          {:error, :invalid_limits}
        end

      {:ok, _config} ->
        {:error, :invalid_limits}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp valid_limits?(default, users) do
    positive_integer?(default) and is_map(users) and
      Enum.all?(users, fn {_user, limit} -> positive_integer?(limit) end)
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
