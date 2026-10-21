defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user N requests in any rolling 60-second window.

  N comes from a JSON file that is read when the limiter starts:

      {
        "default": 60,
        "users": {"42": 300, "77": 10}
      }

  `"default"` applies to every user not listed under `"users"`. Keys under
  `"users"` are strings because JSON object keys are strings. Integer user IDs
  are converted with `to_string/1`, so user `42` and `"42"` are the same user.

  ## Starting

  Add the limiter to the supervision tree with the path to the file:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  If the file is missing or invalid, `start_link/1` returns `{:error, reason}`
  and the application fails to boot.

  ## Callers

  Check the limit before doing the work. `check/1` returns `:ok` or
  `{:error, :rate_limited}`.

  In a controller, put the check in the `with` chain before the work:

      def create(conn, params) do
        user = conn.assigns.current_user

        with :ok <- MyApp.RateLimiter.check(user.id),
             {:ok, order} <- Orders.create_order(user, params) do
          json(conn, %{id: order.id})
        else
          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: changeset.errors})
        end
      end

  In a background job, return an error so the job runner retries later:

      def perform(user_id, export_id) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> Exports.run(export_id)
          {:error, :rate_limited} = error -> error
        end
      end

  ## How it counts

  Each check records the request in an ETS table first and then counts the
  user's requests in the last minute. If the count is over the limit, the
  request's own record is deleted. The insert, count, and delete are each
  atomic, so concurrent checks cannot all read the same count and pass. Under
  a burst, some requests can be rejected that would have fit the limit, but no
  more than N are ever allowed in one window.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @type user_id :: integer() | binary()
  @type result :: :ok | {:error, :rate_limited}

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - process and ETS table name. Defaults to `MyApp.RateLimiter`.
      Tests can pass a different name to run their own instance.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, Keyword.fetch!(opts, :config_path)}, name: name)
  end

  @doc """
  Records a request for `user_id` and returns `:ok` if it is within the limit.

  A rejected request is deleted, so it does not use up the allowance for later
  requests.
  """
  @spec check(user_id()) :: result()
  @spec check(atom(), user_id()) :: result()
  def check(name \\ __MODULE__, user_id)
      when is_integer(user_id) or is_binary(user_id) do
    user_key = user_key(user_id)
    now = now_ms()
    request = {:request, user_key, now, make_ref()}

    :ets.insert(name, {request})

    if count_recent(name, user_key, now - @window_ms) > limit_for(name, user_key) do
      :ets.delete(name, request)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    # Loaded in init/1 rather than handle_continue/2 so that a bad file makes
    # start_link/1 return an error instead of starting a process that stops.
    case load_limits(config_path) do
      {:ok, limits} ->
        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ets.insert(name, limits)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = now_ms() - @window_ms

    # Requests older than the window are never counted, so removing them does
    # not change any result.
    :ets.select_delete(name, [{{{:request, :_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp count_recent(name, user_key, cutoff) do
    :ets.select_count(name, [{{{:request, user_key, :"$1", :_}}, [{:>=, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_key) do
    default = :ets.lookup_element(name, {:limit, :default}, 2)
    :ets.lookup_element(name, {:limit, user_key}, 2, default)
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- File.read(config_path),
         {:ok, config} <- decode_json(contents) do
      parse_limits(config)
    end
  end

  defp decode_json(contents) do
    {:ok, :json.decode(contents)}
  catch
    :error, reason -> {:error, {:invalid_json, reason}}
  end

  defp parse_limits(%{"default" => default} = config) when is_integer(default) and default > 0 do
    users = Map.get(config, "users", %{})

    if is_map(users) and Enum.all?(users, fn {_id, limit} -> is_integer(limit) and limit > 0 end) do
      objects = Enum.map(users, fn {id, limit} -> {{:limit, id}, limit} end)
      {:ok, [{{:limit, :default}, default} | objects]}
    else
      {:error, :invalid_user_limits}
    end
  end

  defp parse_limits(_config), do: {:error, :invalid_limits_config}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp user_key(user_id), do: to_string(user_id)
end
