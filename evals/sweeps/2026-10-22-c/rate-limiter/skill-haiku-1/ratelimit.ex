defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user a fixed number of requests in any rolling minute.

  The limits come from a JSON file that is read when the limiter starts:

      {"default": 60, "users": {"42": 300, "7": 10}}

  `"default"` applies to every user not listed under `"users"`. Keys under
  `"users"` are compared with the user id as a string, so the integer id 42
  is listed as `"42"`.

  Start the limiter under a supervisor:

      children = [
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  Check the limit before doing the work. A controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            render_report(conn, params)

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  A background job checks the same way, and reschedules itself when the
  check returns `{:error, :rate_limited}`.
  """

  use GenServer

  @type user_id :: integer() | String.t()

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.minutes(1)
  # Rows are kept for two windows so that a check which read the clock just
  # before a sweep still sees every row inside its own window.
  @sweep_retention 2 * @window_ms

  @doc """
  Starts the limiter and reads its limits from `:config_path`.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the registered name, which also names the ETS table.
      Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Keyword.validate!(opts, [:config_path, :name])
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records one request for `user_id` and says whether it is within the limit.

  Returns `:ok` when the request is allowed. Returns `{:error, :rate_limited}`
  when the user has already made their limit of requests in the last minute.
  A rejected request is not counted against the user.
  """
  @spec check(user_id()) :: :ok | {:error, :rate_limited}
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = user_key(user_id)
    now = System.monotonic_time(:millisecond)
    row_key = {user, now, :erlang.unique_integer([:monotonic, :positive])}

    # Insert before counting. Of any requests admitted in one window, the one
    # that counts last sees every other request's row, so the limit holds.
    # Rejected rows can turn away a request that would have passed.
    :ets.insert(name, {row_key, true})

    if count_in_window(name, user, now) > limit_for(name, user) do
      :ets.delete(name, row_key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        :ets.new(name, [:named_table, :public, :ordered_set])
        :ets.insert(name, limit_rows(limits))
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @sweep_retention
    :ets.select_delete(name, [{{{:_, :"$1", :_}, :_}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp user_key(user_id) when is_integer(user_id) or is_binary(user_id),
    do: to_string(user_id)

  defp count_in_window(name, user, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user, :"$1", :_}, :_}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user) do
    default = :ets.lookup_element(name, {:limit, :default}, 2)
    :ets.lookup_element(name, {:limit, user}, 2, default)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp limit_rows(%{default: default, users: users}) do
    user_rows = Enum.map(users, fn {user, limit} -> {{:limit, user}, limit} end)
    [{{:limit, :default}, default} | user_rows]
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp decode_json(contents) do
    {:ok, :json.decode(contents)}
  rescue
    ErlangError -> {:error, :invalid_json}
  end

  defp parse_limits(%{"default" => default} = decoded) do
    users = Map.get(decoded, "users", %{})

    if valid_limit?(default) and valid_users?(users) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse_limits(_decoded), do: {:error, :missing_default_limit}

  defp valid_users?(users) do
    is_map(users) and Enum.all?(users, fn {_user, limit} -> valid_limit?(limit) end)
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end
