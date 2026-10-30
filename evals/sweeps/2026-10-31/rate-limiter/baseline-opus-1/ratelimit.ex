defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any rolling
  60-second window, where N comes from a JSON file read when the limiter starts.

  `check/1` is the only call the rest of the app needs. It tests the limit and
  records the request as one atomic step, so call it once per unit of work,
  immediately before doing that work. Denied requests are not recorded and do
  not extend the wait.

  ## Configuration file

      {
        "default": 60,
        "users": {
          "42": 600,
          "1017": 0
        }
      }

  `"default"` applies to every user not listed under `"users"`. Both keys are
  required. A limit of 0 blocks the user. User ids are compared as strings, so
  `42` and `"42"` are the same user.

  A missing or invalid file stops the limiter from starting, and so stops the
  app from booting. Restarting the limiter rereads the file and forgets all
  recorded requests.

  ## Starting it

  Add it to the supervision tree ahead of anything that calls it:

      # lib/my_app/application.ex
      def start(_type, _args) do
        children = [
          {MyApp.RateLimiter, path: Application.app_dir(:my_app, "priv/rate_limits.json")},
          {Oban, Application.fetch_env!(:my_app, Oban)},
          MyAppWeb.Endpoint
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
      end

  ## Calling it

  Controllers share a plug, which must run after whatever sets `current_user`:

      defmodule MyAppWeb.Plugs.RateLimit do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(retry_after))
              |> send_resp(:too_many_requests, "")
              |> halt()
          end
        end
      end

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        plug MyAppWeb.Plugs.RateLimit

        def show(conn, %{"id" => id}) do
          render(conn, :show, report: MyApp.Reports.get!(id))
        end
      end

  Background jobs call it directly and come back later when denied:

      defmodule MyApp.Workers.ExportReport do
        use Oban.Worker, queue: :reports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id, "report_id" => report_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Reports.export(user_id, report_id)
            {:error, {:rate_limited, retry_after}} -> {:snooze, retry_after}
          end
        end
      end

  ## Behaviour to plan around

  `check/1` runs in the calling process against an ETS (Erlang Term Storage)
  table, so callers never queue behind a single process. The GenServer only owns
  the table and clears out idle users once a minute.

  Each node counts on its own and keeps its counts in memory. On a cluster of K
  nodes a user can reach K x N requests per minute, and a restart resets counts.
  A cluster-wide limit needs a shared store such as Redis.

  If the limiter is not running, `check/1` raises `ArgumentError`, so the request
  fails rather than running unlimited. The process does little enough that a
  crash is unlikely, and its supervisor restarts it straight away.

  Each check copies the user's list of recent timestamps, so its cost grows with
  N: about 40 microseconds per 1,000 recent requests, measured on a laptop. That
  is small at limits in the low thousands per minute. Limits far above that would
  be better served by per-second counters, at the price of one-second precision.
  """

  use GenServer

  @window_ms 60_000

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter.

  Options:

    * `:path` - path of the JSON configuration file. Required.
    * `:name` - process and table name, for running a separate instance in
      tests. Defaults to `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, Keyword.fetch!(opts, :path)}, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok` if the work may go ahead. Otherwise returns
  `{:error, {:rate_limited, retry_after}}`, where `retry_after` is the number of
  whole seconds, rounded up, until the user's next slot frees. For a user whose
  limit is 0 no slot will free, and `retry_after` is the length of the window.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(limiter \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    key = to_string(user_id)
    {default, users} = :persistent_term.get({__MODULE__, limiter})
    take_slot(limiter, key, Map.get(users, key, default))
  end

  defp take_slot(_table, _key, 0), do: {:error, {:rate_limited, seconds(@window_ms)}}

  defp take_slot(table, key, limit) do
    stored = :ets.lookup(table, key)

    # Read the clock after the lookup so `now` is never older than a stamp in
    # `stored`. That keeps each list newest-first, which the pruning here and
    # the sweep both rely on.
    now = System.monotonic_time(:millisecond)
    live = stored |> stamps() |> Enum.take_while(&(now - &1 < @window_ms))

    cond do
      length(live) >= limit ->
        {:error, {:rate_limited, seconds(List.last(live) + @window_ms - now)}}

      store(table, stored, {key, [now | live]}) ->
        :ok

      # Another process changed this row first. Every failed attempt means some
      # other request was admitted or swept, so this ends once the user is full.
      true ->
        take_slot(table, key, limit)
    end
  end

  defp stamps([]), do: []
  defp stamps([{_key, stamps}]), do: stamps

  defp store(table, [], row), do: :ets.insert_new(table, row)

  # Compare-and-swap: replaces the row only if it still equals `old`.
  defp store(table, [old], row) do
    :ets.select_replace(table, [{old, [], [{:const, row}]}]) == 1
  end

  defp seconds(ms), do: ceil(ms / 1000)

  # The configuration is read here rather than in a `handle_continue/2` so that
  # the supervisor starts nothing that calls the limiter until the limits exist.
  @impl GenServer
  def init({name, path}) do
    case read_limits(path) do
      {:ok, limits} ->
        # Written once per start and read on every check, which suits
        # persistent_term: reads do not copy the map.
        :persistent_term.put({__MODULE__, name}, limits)
        :ets.new(name, [:named_table, :public, write_concurrency: :auto])
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, path, reason}}
    end
  end

  # Only admitted requests write to a row, so users who go quiet need removing
  # here. The head of each list is its newest stamp: if that has expired, they
  # all have.
  @impl GenServer
  def handle_info(:sweep, table) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(table, [{{:_, [:"$1" | :_]}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, table}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)

  defp read_limits(path) do
    with {:ok, json} <- File.read(path),
         {:ok, config} <- JSON.decode(json) do
      validate(config)
    end
  end

  defp validate(%{"default" => default, "users" => %{} = users}) do
    entries = [{"default", default} | Map.to_list(users)]
    invalid = for {user, limit} <- entries, not valid_limit?(limit), do: user

    if invalid == [], do: {:ok, {default, users}}, else: {:error, {:invalid_limits, invalid}}
  end

  defp validate(_config), do: {:error, :expected_default_and_users}

  defp valid_limit?(limit), do: is_integer(limit) and limit >= 0
end
