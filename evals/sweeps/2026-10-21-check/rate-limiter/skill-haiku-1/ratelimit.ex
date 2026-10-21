defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling window (60 seconds by default).

  Each user's limit comes from a JSON file read when the limiter starts:

      {
        "default": 60,
        "users": {
          "42": 300
        }
      }

  `"default"` applies to every user not listed under `"users"`. User IDs are
  compared by their string form, so ID `42` and `"42"` are the same user.

  ## Starting

  Add the limiter to the supervision tree:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  Startup fails if the file is missing or its contents are invalid.

  ## Callers

  Controllers check the limit before doing the work:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        plug :rate_limit

        def create(conn, params) do
          json(conn, %{report: MyApp.Reports.build(params)})
        end

        defp rate_limit(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
              |> halt()
          end
        end
      end

  Background jobs check the same way and reschedule when limited:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Exports.run(user_id)
          {:error, :rate_limited} -> {:snooze, 30}
        end
      end
  """

  use GenServer

  @default_window_ms :timer.seconds(60)
  @sweep_interval :timer.seconds(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the registered name, which is also the name of the ETS table.
      Defaults to the module name. Tests pass a different name to run their own copy.
    * `:window_ms` - length of the rolling window in milliseconds. Defaults to 60 seconds.
  """
  def start_link(opts) do
    config =
      Keyword.validate!(opts, [:config_path, name: __MODULE__, window_ms: @default_window_ms])

    GenServer.start_link(__MODULE__, config, name: config[:name])
  end

  @doc """
  Records one request for `user_id` and returns `:ok` if it is within the user's limit.

  Returns `{:error, :rate_limited}` when the user has already made their limit of
  requests in the window. A rejected request is not counted.

  This runs in the caller's process and does not call the limiter process.
  """
  @spec check(atom(), term()) :: :ok | {:error, :rate_limited}
  @spec check(term()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    key = {:request, user, :erlang.unique_integer([:monotonic])}

    # Insert before counting. Two concurrent requests then see each other's rows,
    # so the limit holds. Counting first and inserting after would let both through.
    :ets.insert(name, {key, now})

    if count_in_window(name, user, now) > limit_for(name, user) do
      :ets.delete(name, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init(config) do
    name = Keyword.fetch!(config, :name)
    window_ms = Keyword.fetch!(config, :window_ms)

    with {:ok, limits} <- read_limits(Keyword.fetch!(config, :config_path)) do
      :ets.new(name, [
        :named_table,
        :public,
        :ordered_set,
        read_concurrency: true,
        write_concurrency: true
      ])

      user_limits = Enum.map(limits.users, fn {id, limit} -> {{:limit, id}, limit} end)
      :ets.insert(name, [{:window_ms, window_ms}, {:default, limits.default} | user_limits])
      schedule_sweep()

      {:ok, name}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - window_ms(name)
    :ets.select_delete(name, [{{{:request, :_, :_}, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()

    {:noreply, name}
  end

  defp count_in_window(name, user, now) do
    cutoff = now - window_ms(name)
    :ets.select_count(name, [{{{:request, user, :_}, :"$1"}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default, 2)
    end
  end

  defp window_ms(name), do: :ets.lookup_element(name, :window_ms, 2)

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp read_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_limits(decoded)
    else
      {:error, reason} -> {:error, {:unreadable_config, path, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = config) do
    users = Map.get(config, "users", %{})

    if valid_limit?(default) and is_map(users) and
         Enum.all?(users, fn {_id, limit} -> valid_limit?(limit) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_limits}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end
