defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any
  rolling minute.

  N comes from a limits file read once when the limiter starts. The file is an
  Elixir script that evaluates to a map:

      %{
        default: 60,
        users: %{
          "user-17" => 600,
          "user-99" => 5
        }
      }

  A user missing from `:users` gets `:default`.

  ## How it works

  Callers run `check/2` in their own process, so requests do not queue behind
  one process. Every check inserts one row per request into an ETS (Erlang
  Term Storage) table, counts the user's rows from the last minute, and removes
  its own row when the count is over the limit. Each step is atomic by itself,
  so concurrent requests never get more than N through. Under heavy
  concurrency at the limit, two simultaneous requests may both be refused when
  only one of them needed to be.

  The owning process creates the table and sweeps expired rows once a minute,
  so the table does not grow without bound.

  ## Starting it

  Add it to the application's supervision tree, before the endpoint and
  before anything that runs background jobs:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

  with `config :my_app, rate_limits_path: "priv/rate_limits.exs"` in
  `config/runtime.exs`.

  ## Calling it from a controller

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            # do the work
            conn

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate limit exceeded"})
        end
      end

  ## Calling it from a background job

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: term()

  @doc """
  Starts the limiter.

  ## Options

    * `:limits_path` - path of the limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    name = Keyword.fetch!(opts, :name)
    limits_path = Keyword.fetch!(opts, :limits_path)
    GenServer.start_link(__MODULE__, {name, limits_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit for the last minute, and
  `{:error, :rate_limited}` when they are not. A refused request is not
  counted against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    request = {user_id, now, :erlang.unique_integer([:positive])}
    true = :ets.insert(name, {request})

    if count_since(name, user_id, now - @window_ms) <= limit_for(name, user_id) do
      :ok
    else
      :ets.delete(name, request)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, limits_path}) do
    table_options = [
      :named_table,
      :public,
      :ordered_set,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    :persistent_term.put({__MODULE__, name}, read_limits!(limits_path))
    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    sweep(name)
    schedule_sweep()
    {:noreply, name}
  end

  defp read_limits!(path) do
    {%{default: default, users: users}, _bindings} = Code.eval_file(path)
    true = is_integer(default) and default >= 0
    true = Enum.all?(users, fn {_user_id, limit} -> is_integer(limit) and limit >= 0 end)
    %{default: default, users: users}
  end

  defp limit_for(name, user_id) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, user_id, limits.default)
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  defp sweep(name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, match_spec)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
