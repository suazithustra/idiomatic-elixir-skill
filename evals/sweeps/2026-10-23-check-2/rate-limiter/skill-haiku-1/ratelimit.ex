defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  Limits come from a JSON file that is read once, when the limiter starts:

      {"default": 60, "users": {"42": 120, "7": 300}}

  `default` applies to every user not listed under `users`. Keys under `users`
  are user IDs as strings; an integer ID is matched by its string form.

  ## Starting

  Add the limiter to the supervision tree:

      children = [
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Checking

  Call `check/2` before the work starts. A controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            do_create(conn, params)

          {:error, {:rate_limited, retry_after_ms}} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
            |> send_resp(:too_many_requests, "")
        end
      end

  A background job checks the same way and returns `{:snooze, seconds}` (Oban)
  or reschedules itself when the check fails.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()
  @type check_result :: :ok | {:error, {:rate_limited, retry_after_ms :: pos_integer()}}

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the registered name. Defaults to the module name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, config_path, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Records one request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed. Otherwise returns
  `{:error, {:rate_limited, retry_after_ms}}`, where `retry_after_ms` is the time
  until the user's next slot opens. A rejected request is not recorded.
  """
  @spec check(GenServer.server(), user_id()) :: check_result()
  def check(server \\ __MODULE__, user_id)
      when is_binary(user_id) or is_integer(user_id) do
    GenServer.call(server, {:check, user_id})
  end

  @impl true
  def init(config_path) do
    case read_limits(config_path) do
      {:ok, limits} ->
        schedule_sweep()
        {:ok, %{limits: limits, requests: %{}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    # Read, prune, and write in one message. Two concurrent requests cannot
    # both see the last free slot, because the process handles them one at a time.
    now = System.monotonic_time(:millisecond)
    limit = limit_for(state.limits, user_id)
    recent = in_window(Map.get(state.requests, user_id, []), now)

    case admit(recent, limit, now) do
      :ok ->
        {:reply, :ok, put_requests(state, user_id, [now | recent])}

      {:error, _reason} = error ->
        {:reply, error, put_requests(state, user_id, recent)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    requests =
      state.requests
      |> Map.new(fn {user_id, timestamps} -> {user_id, in_window(timestamps, now)} end)
      |> Map.reject(fn {_user_id, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | requests: requests}}
  end

  defp admit(recent, limit, now) do
    if length(recent) < limit do
      :ok
    else
      # Timestamps are newest first. The user has a free slot once the entry at
      # position limit - 1 leaves the window, because everything newer stays.
      blocking_at = Enum.at(recent, limit - 1)
      {:error, {:rate_limited, blocking_at + @window_ms - now}}
    end
  end

  defp in_window(timestamps, now) do
    Enum.take_while(timestamps, &(&1 > now - @window_ms))
  end

  defp limit_for(limits, user_id) do
    Map.get(limits.users, to_string(user_id), limits.default)
  end

  defp put_requests(state, user_id, timestamps) do
    %{state | requests: Map.put(state.requests, user_id, timestamps)}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp read_limits(config_path) do
    with {:ok, contents} <- read_file(config_path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(config_path) do
    case File.read(config_path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, config_path, reason}}
    end
  end

  # :json (OTP 27+) has no non-raising decode, so the parse error is caught here.
  defp decode_json(contents) do
    {:ok, :json.decode(contents)}
  rescue
    error in ErlangError -> {:error, {:invalid_json, error.original}}
  end

  defp parse_limits(%{"default" => default} = decoded) do
    users = Map.get(decoded, "users", %{})

    with :ok <- validate_limit("default", default),
         :ok <- validate_users(users) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_decoded), do: {:error, :missing_default_limit}

  defp validate_limit(key, limit) do
    if valid_limit?(limit), do: :ok, else: {:error, {:invalid_limit, key, limit}}
  end

  defp validate_users(users) when is_map(users) do
    case Enum.find(users, fn {_user_id, limit} -> not valid_limit?(limit) end) do
      nil -> :ok
      {user_id, limit} -> {:error, {:invalid_limit, user_id, limit}}
    end
  end

  defp validate_users(users), do: {:error, {:invalid_users, users}}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end
