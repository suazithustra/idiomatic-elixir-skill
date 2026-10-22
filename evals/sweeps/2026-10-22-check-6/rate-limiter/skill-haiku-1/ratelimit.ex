defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user a fixed number of requests in a rolling minute.

  Limits come from a JSON file read when the limiter starts. The file holds a
  `"default"` limit, which applies to any user not listed, and an optional
  `"users"` object that maps user IDs to their own limits:

      {"default": 60, "users": {"42": 300, "7": 0}}

  User IDs are strings in the file. `check/2` accepts an integer or a string,
  so `check(42)` and `check("42")` use the same entry.

  ## Starting it

  Add it to the supervision tree with the path to the file:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  A missing file, invalid JSON, or a limit that is not a non-negative integer
  stops the start with an error. Request history is kept in memory, so a
  restart clears it.

  ## Calling it

  Call `check/2` before doing the work. It records the request, so call it once
  per request, not once per check of the same request.

  In a controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            create_report(conn, params)

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  In a background job:

      def run(user_id) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> export_reports(user_id)
          {:error, :rate_limited} = error -> error
        end
      end
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.seconds(30)

  @doc """
  Starts the limiter and loads its limits.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the process and ETS table name. Defaults to `#{__MODULE__}`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and returns `:ok` if it is within the user's
  limit for the last minute, or `{:error, :rate_limited}` if it is not.

  A rejected request is not counted against the user.
  """
  def check(name \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    user = to_string(user_id)
    limit = limit_for(name, user)
    now = System.monotonic_time(:millisecond)
    key = {:request, user, :erlang.unique_integer([:monotonic, :positive])}

    # Record before counting. Two checks that count before either has recorded
    # itself would both see room and both be allowed.
    true = :ets.insert(name, {key, now})

    if count_requests(name, user, now) <= limit do
      :ok
    else
      true = :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    entries = load_limits(config_path)

    :ets.new(name, [:named_table, :ordered_set, :public, read_concurrency: true])
    true = :ets.insert(name, entries)
    schedule_sweep()

    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window
    :ets.select_delete(name, [{{{:request, :_, :_}, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()

    {:noreply, name}
  end

  defp limit_for(name, user) do
    default = :ets.lookup_element(name, {:limit, :default}, 2)
    :ets.lookup_element(name, {:limit, user}, 2, default)
  end

  defp count_requests(name, user, now) do
    cutoff = now - @window

    :ets.select_count(name, [
      {{{:request, user, :_}, :"$1"}, [{:>, :"$1", cutoff}], [true]}
    ])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp load_limits(config_path) do
    %{"default" => default} = config = config_path |> File.read!() |> JSON.decode!()

    user_limits =
      for {user, limit} <- Map.get(config, "users", %{}) do
        {{:limit, user}, validate_limit!(limit)}
      end

    [{{:limit, :default}, validate_limit!(default)} | user_limits]
  end

  defp validate_limit!(limit) when is_integer(limit) and limit >= 0, do: limit

  defp validate_limit!(other) do
    raise ArgumentError, "rate limit must be a non-negative integer, got: #{inspect(other)}"
  end
end
