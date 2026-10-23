defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling 60-second window.

  N comes from a JSON file read once, when the limiter starts:

      {
        "default": 60,
        "users": {"42": 300, "77": 10}
      }

  Users not listed under `"users"` get `"default"`. Keys under `"users"` are
  strings. `check/1` accepts integer or string user IDs and converts them with
  `to_string/1`.

  ## Starting

  Add the limiter to the supervision tree of the application:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint
      ]

  A malformed config file or a limit that is not a positive integer stops the
  start with an error, so the problem shows at boot.

  ## Callers

  A controller action:

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
          :ok -> run_export(job)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @requests_table __MODULE__.Requests
  @limits_table __MODULE__.Limits

  @doc """
  Starts the limiter and reads its limits from the file at `:config_path`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config_path), name: __MODULE__)
  end

  @doc """
  Counts one request for `user_id` and reports whether it is within the limit.

  Returns `:ok` when the user has made fewer than N requests in the last 60
  seconds, counting this one. Returns `{:error, :rate_limited}` otherwise, and
  the rejected request is not counted.
  """
  @spec check(integer() | String.t()) :: :ok | {:error, :rate_limited}
  def check(user_id) when is_integer(user_id) or is_binary(user_id) do
    user_key = to_string(user_id)
    limit = limit_for(user_key)
    now = System.monotonic_time(:millisecond)
    key = {user_key, now, System.unique_integer([:positive, :monotonic])}

    # Insert before counting. A check that counted, then inserted, would let two
    # concurrent requests both see room and both pass.
    :ets.insert(@requests_table, {key, true})

    if count_recent(user_key, now) > limit do
      :ets.delete(@requests_table, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init(config_path) do
    case read_limits(config_path) do
      {:ok, {default, users}} -> start_tables(default, users)
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    expired = [{{{:_, :"$1", :_}, :_}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(@requests_table, expired)

    schedule_sweep()
    {:noreply, state}
  end

  defp limit_for(user_key) do
    case :ets.lookup(@limits_table, user_key) do
      [{_user_key, limit}] -> limit
      [] -> :ets.lookup_element(@limits_table, :default, 2)
    end
  end

  # The ordered_set key starts with the user, so this scans only that user's rows.
  defp count_recent(user_key, now) do
    cutoff = now - @window_ms
    recent = [{{{user_key, :"$1", :_}, :_}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(@requests_table, recent)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  defp start_tables(default, users) do
    :ets.new(@requests_table, [:named_table, :public, :ordered_set, write_concurrency: true])
    :ets.new(@limits_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@limits_table, [{:default, default} | Map.to_list(users)])

    schedule_sweep()
    {:ok, nil}
  end

  defp read_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, config} <- decode_json(contents) do
      build_limits(config)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, path, reason}}
    end
  end

  # :json.decode/1 has no non-raising version, so this catches only that call.
  defp decode_json(contents) do
    {:ok, :json.decode(contents)}
  catch
    :error, reason -> {:error, {:invalid_json, reason}}
  end

  defp build_limits(%{"default" => default, "users" => users}) when is_map(users) do
    if Enum.all?([default | Map.values(users)], &valid_limit?/1) do
      {:ok, {default, users}}
    else
      {:error, :limits_must_be_positive_integers}
    end
  end

  defp build_limits(_config), do: {:error, :missing_default_or_users}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end
