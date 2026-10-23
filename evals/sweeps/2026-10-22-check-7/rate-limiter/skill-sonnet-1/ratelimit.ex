defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter allowing at most N requests in any rolling minute.

  Each user's N comes from a limits file read once, when the limiter starts.
  The file holds Erlang terms, each ending in a period: `{user_id, limit}.`
  entries and an optional `{default, limit}.` for users not listed. Without
  a default entry, unlisted users are always rejected.

      {default, 60}.
      {42, 600}.
      {<<"7f3a9c">>, 6000}.

  The file is Erlang syntax, so a string ID is written `<<"7f3a9c">>`.

  User IDs must not be `:_` or an atom starting with `$`, since they are used
  inside ETS match patterns.

  Every accepted request is one row in a public ETS table, so callers check
  the limit from their own process and never queue behind the owner process.

  ## Starting

  Add it to the application's supervision tree, before the endpoint:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_path: "priv/rate_limits.terms"},
        MyAppWeb.Endpoint
      ]

  Without `:limits_path`, the limiter reads the `:limits_path` entry under
  `config :my_app, MyApp.RateLimiter` at startup.

  ## Calling from a controller

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          {:ok, _remaining} ->
            # do the work
            send_resp(conn, 201, "")

          {:error, :rate_limited} ->
            conn
            |> put_resp_header("retry-after", "60")
            |> send_resp(429, "Too many requests")
        end
      end

  Background jobs use the same function, for example by snoozing the job
  when it returns `{:error, :rate_limited}`.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: term()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:limits_path` - path of the limits file. Defaults to the
      `:limits_path` entry of `config :my_app, MyApp.RateLimiter`.
    * `:name` - the process name, which is also the ETS table name.
      Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a request by `user_id` unless the user is over their limit.

  Returns `{:ok, remaining}` with the requests left in the current rolling
  minute, or `{:error, :rate_limited}`. A rejected request is not counted.
  """
  @spec check(atom(), user_id()) :: {:ok, non_neg_integer()} | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    limit = limit_for(name, user_id)
    now = System.monotonic_time(:millisecond)
    row_key = {:hit, user_id, now, make_ref()}

    # Insert first, then count: a lookup-then-insert would let concurrent
    # callers all pass. Concurrent rejections may cost each other a slot,
    # but the limit is never exceeded.
    :ets.insert(name, {row_key, nil})

    case count_since(name, user_id, now - @window_ms) do
      count when count <= limit ->
        {:ok, limit - count}

      _over_limit ->
        :ets.delete(name, row_key)
        {:error, :rate_limited}
    end
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    path = Keyword.get_lazy(opts, :limits_path, &configured_limits_path/0)

    case read_limits(path) do
      {:ok, limits} ->
        table_options = [:named_table, :public, :ordered_set, write_concurrency: true]
        :ets.new(name, table_options)

        Enum.each(limits, fn {user_id, limit} -> :ets.insert(name, {{:limit, user_id}, limit}) end)

        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_limits_file, path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:hit, :_, :"$1", :_}, :_}, [{:"=<", :"$1", cutoff}], [true]}]

    :ets.select_delete(name, match_spec)
    schedule_sweep()
    {:noreply, name}
  end

  defp configured_limits_path do
    :my_app
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:limits_path)
  end

  defp read_limits(path) do
    case :file.consult(path) do
      {:ok, entries} -> validate_entries(entries)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_entries(entries) do
    case Enum.find(entries, &(not valid_entry?(&1))) do
      nil -> {:ok, entries}
      entry -> {:error, {:invalid_entry, entry}}
    end
  end

  defp valid_entry?({_user_id, limit}), do: is_integer(limit) and limit >= 0
  defp valid_entry?(_entry), do: false

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> default_limit(name)
    end
  end

  defp default_limit(name) do
    case :ets.lookup(name, {:limit, :default}) do
      [{_key, limit}] -> limit
      [] -> 0
    end
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{:hit, user_id, :"$1", :_}, :_}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
