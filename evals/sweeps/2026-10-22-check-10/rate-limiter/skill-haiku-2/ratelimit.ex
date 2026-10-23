defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling minute.

  Controllers and background jobs call `check/1` before they do work for a
  user:

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work(user)
        {:error, :rate_limited} -> {:error, :rate_limited}
      end

  Each user's limit comes from a JSON file that is read when this process
  starts:

      {"default": 60, "users": {"42": 300}}

  `"default"` applies to every user not listed under `"users"`. User IDs are
  matched by their string form, so `42` and `"42"` are the same user. The
  file's path is the `:config_path` start option, or else the
  `:rate_limits_file` key of the `:my_app` application environment.

  ## Starting

  Add the limiter to the supervision tree before the processes that call it:

      children = [
        MyApp.Repo,
        MyApp.RateLimiter,
        MyAppWeb.Endpoint
      ]

  ## Example caller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, _params) do
          user = conn.assigns.current_user

          case RateLimiter.check(user.id) do
            :ok ->
              render_report(conn, user)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  Callers read and write the ETS tables directly instead of calling this
  process, so checks never queue behind each other. Each call to `check/1`
  counts as one request, including one whose work later fails.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(10)
  @requests_table Module.concat(__MODULE__, Requests)
  @limits_table Module.concat(__MODULE__, Limits)

  @doc """
  Starts the limiter and reads the limits from its config file.

  ## Options

    * `:config_path` - the JSON file with the limits. Defaults to the
      `:rate_limits_file` key of the `:my_app` application environment.
  """
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:config_path])
    config_path = opts[:config_path] || Application.fetch_env!(:my_app, :rate_limits_file)

    GenServer.start_link(__MODULE__, config_path, name: __MODULE__)
  end

  @doc """
  Records one request by `user_id`.

  Returns `:ok` when the user is within their limit for the last minute, or
  `{:error, :rate_limited}` when they are over it. A rejected request is not
  counted.
  """
  @spec check(term()) :: :ok | {:error, :rate_limited}
  def check(user_id) do
    user_key = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    request = {user_key, now, System.unique_integer([:monotonic])}

    # Insert before counting. Two requests that race each see the other's row,
    # so the count can overstate usage but never admit more than the limit.
    :ets.insert(@requests_table, {request})

    if count_in_window(user_key, now) > limit_for(user_key) do
      :ets.delete(@requests_table, request)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init(config_path) do
    :ets.new(@requests_table, [:named_table, :public, :ordered_set, write_concurrency: true])
    :ets.new(@limits_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.insert(@limits_table, load_limits!(config_path))
    schedule_sweep()

    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Keep two windows of history, not one. A check that read its clock just
    # before this sweep must still find every row it counts.
    cutoff = System.monotonic_time(:millisecond) - 2 * @window_ms
    :ets.select_delete(@requests_table, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()

    {:noreply, state}
  end

  defp count_in_window(user_key, now) do
    cutoff = now - @window_ms

    :ets.select_count(@requests_table, [
      {{{user_key, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}
    ])
  end

  defp limit_for(user_key) do
    case :ets.lookup(@limits_table, user_key) do
      [{^user_key, limit}] -> limit
      [] -> :ets.lookup_element(@limits_table, :default, 2)
    end
  end

  defp load_limits!(config_path) do
    json = File.read!(config_path)
    %{"default" => default, "users" => users} = Jason.decode!(json)

    [{:default, default} | Map.to_list(users)]
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
