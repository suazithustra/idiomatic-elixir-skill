defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests per rolling minute.

  Limits come from a JSON file read once when the limiter starts:

      {"default": 60, "users": {"42": 600, "7": 10}}

  A user without an entry under `"users"` gets `"default"`. If the file is missing
  or malformed the limiter fails to start, so a bad deploy is caught at boot.

  Every request is stored as one row in a public ETS table owned by this process,
  so callers check the limit from their own process without queueing behind a
  single GenServer. `check/2` inserts the row first, then counts the user's rows
  in the last minute, and removes its own row when the count is over the limit.
  Concurrent callers therefore cannot both slip under the limit, which a
  read-then-write of a timestamp list would allow.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_path` - path of the JSON limits file. Required.
    * `:name` - registered name and ETS table name. Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit, or
  `{:error, :rate_limited}` when they are over it. A rejected request does not
  count against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    request_id = {user, now, :erlang.unique_integer([:monotonic])}

    :ets.insert(name, {request_id})

    if count_since(name, user, now - @window_ms) <= limit_for(name, user) do
      :ok
    else
      :ets.delete(name, request_id)
      {:error, :rate_limited}
    end
  end

  defp count_since(name, user, cutoff) do
    match_spec = [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]

    :ets.select_count(name, match_spec)
  end

  defp limit_for(name, user) do
    case :ets.lookup(limits_table(name), user) do
      [{^user, limit}] -> limit
      [] -> :ets.lookup_element(limits_table(name), :default, 2)
    end
  end

  defp limits_table(name), do: :"#{name}.limits"

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.fetch!(opts, :limits_path)

    case load_limits(path) do
      {:ok, limits} ->
        # ordered_set so counting one user's rows scans only that user's key range
        :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
        limits_table = limits_table(name)
        :ets.new(limits_table, [:named_table, :protected, read_concurrency: true])
        :ets.insert(limits_table, limits)

        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_limits, path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])

    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:malformed_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) when is_integer(default) and default > 0 do
    user_limits = Map.get(decoded, "users", %{})

    if valid_user_limits?(user_limits) do
      {:ok, [{:default, default} | Map.to_list(user_limits)]}
    else
      {:error, {:invalid_field, "users"}}
    end
  end

  defp parse_limits(%{"default" => _default}), do: {:error, {:invalid_field, "default"}}
  defp parse_limits(_decoded), do: {:error, {:missing_field, "default"}}

  defp valid_user_limits?(user_limits) when is_map(user_limits) do
    Enum.all?(user_limits, fn {_user, limit} -> is_integer(limit) and limit > 0 end)
  end

  defp valid_user_limits?(_user_limits), do: false
end

# --- How it is started -------------------------------------------------------
#
# lib/my_app/application.ex
#
#     def start(_type, _args) do
#       children = [
#         MyApp.Repo,
#         {MyApp.RateLimiter, limits_path: Application.fetch_env!(:my_app, :rate_limits_path)},
#         MyAppWeb.Endpoint
#       ]
#
#       Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
#     end
#
# config/runtime.exs
#
#     config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

# --- Example callers ---------------------------------------------------------
#
# A controller plug (lib/my_app_web/plugs/rate_limit.ex), added to a pipeline or controller:
#
#     defmodule MyAppWeb.Plugs.RateLimit do
#       @moduledoc false
#
#       import Plug.Conn
#
#       def init(opts), do: opts
#
#       def call(%{assigns: %{current_user: user}} = conn, _opts) do
#         case MyApp.RateLimiter.check(user.id) do
#           :ok ->
#             conn
#
#           {:error, :rate_limited} ->
#             conn
#             |> put_resp_header("retry-after", "60")
#             |> send_resp(429, "Too many requests")
#             |> halt()
#         end
#       end
#     end
#
# A background job (an Oban worker):
#
#     def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
#       case MyApp.RateLimiter.check(user_id) do
#         :ok -> MyApp.Contacts.sync(user_id)
#         {:error, :rate_limited} -> {:snooze, 60}
#       end
#     end
