defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a number of requests in any rolling minute.

  The limits come from a JSON file read when the limiter starts:

      {"default": 60, "users": {"42": 300}}

  `"default"` applies to every user not listed under `"users"`. User IDs are
  compared by their string form, so `42` and `"42"` are the same user.

  ## Starting

  Add the limiter to the application's supervision tree:

      children = [
        {MyApp.RateLimiter,
         config_file: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Callers

  Controllers and background jobs call `check/1` before doing the work:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              report = Reports.build(params)
              json(conn, %{id: report.id})

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limit exceeded"})
          end
        end
      end

      def perform(%Oban.Job{args: %{"user_id" => user_id}} = job) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> run_export(job)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end

  ## Design

  Each allowed request is one row in an ETS table owned by the limiter. A
  request inserts its row first and then counts the user's rows from the last
  minute. A request whose count is over the limit deletes its own row. Callers
  never wait on the limiter process, and no request can be admitted above the
  limit, because the last admitted request always sees every earlier admitted
  row when it counts.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(30)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_file` - path to the JSON limits file. Required.
    * `:name` - the registered name, which is also the name of the ETS table.
      Defaults to `#{inspect(__MODULE__)}`. Tests use a distinct name.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_file, name: __MODULE__])
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Records a request by `user_id` and reports whether it is within the limit.

  Returns `:ok` when the request is allowed. Returns `{:error, :rate_limited}`
  when the user has already made their limit of requests in the last minute.
  A rejected request is not counted.
  """
  @spec check(term(), atom()) :: :ok | {:error, :rate_limited}
  def check(user_id, name \\ __MODULE__) do
    user = to_string(user_id)
    limit = limit_for(user, name)
    now = System.monotonic_time(:millisecond)
    key = {user, now, System.unique_integer([:monotonic])}

    # The row goes in before the count, so two requests racing each other
    # each see the other's row. A lookup-then-insert would let both pass.
    :ets.insert(name, {key})

    if count_since(name, user, now - @window_ms) <= limit do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    case read_limits(Keyword.fetch!(opts, :config_file)) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, limits)

        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp limit_for(user, name) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user, default)
  end

  defp count_since(name, user, since) do
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", since}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp read_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, reason}}
    end
  end

  defp decode(contents) do
    {:ok, :json.decode(contents)}
  rescue
    ErlangError -> {:error, :invalid_json}
  end

  defp parse_limits(%{"default" => default} = config) when is_integer(default) and default >= 0 do
    users = Map.get(config, "users", %{})

    if is_map(users) and Enum.all?(users, fn {_user, limit} -> valid_limit?(limit) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limits}
    end
  end

  defp parse_limits(_config), do: {:error, :invalid_limits}

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end
