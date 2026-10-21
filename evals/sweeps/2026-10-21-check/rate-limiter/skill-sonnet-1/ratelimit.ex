defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling
  minute.

  Limits come from an Erlang-term file read once when the limiter starts. The
  file holds one `{user_id, limit}.` term per line, and a `{:default, limit}.`
  term for users without their own entry:

      {:default, 60}.
      {"user-42", 600}.
      {17, 10}.

  Requests are recorded in an ETS (Erlang Term Storage) table owned by this
  process, but `check/2` runs in the caller's process, so callers do not queue
  behind each other. Each check inserts a row for the request, counts the
  user's rows from the last minute, and deletes its own row if the count is
  over the limit. Insert-then-count means concurrent callers cannot both see
  room for one more request.

  ## Starting it

  Add it to the application's supervision tree before the endpoint and any
  job processor that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

  ## Calling it from a controller

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case MyApp.RateLimiter.check(user.id) do
            :ok ->
              {:ok, report} = MyApp.Reports.generate(user, params)
              json(conn, report)

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate limited"})
          end
        end
      end

  ## Calling it from a background job

      defmodule MyApp.Workers.SyncAccount do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Accounts.sync(user_id)
            {:error, :rate_limited} -> {:snooze, 30}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:config_path` - path to the limits file. Required.
    * `:name` - registered name, which is also the ETS table name. Defaults to
      `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  A rejected request is not counted against the user.

  ## Examples

      MyApp.RateLimiter.check("user-42")
      #=> :ok

      MyApp.RateLimiter.check("user-42")
      #=> {:error, :rate_limited}
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    limit = limit_for(name, user_id)
    now = System.monotonic_time(:millisecond)
    row_key = {:request, user_id, now, :erlang.unique_integer([:monotonic])}

    :ets.insert(name, {row_key})

    if count_since(name, user_id, now - @window_ms) <= limit do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    case read_limits(config_path) do
      {:ok, limits} ->
        :ets.new(name, [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ets.insert(name, for({user_id, limit} <- limits, do: {{:limit, user_id}, limit}))
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_limits_file, config_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms

    :ets.select_delete(name, [
      {{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}
    ])

    schedule_sweep()
    {:noreply, name}
  end

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, {:limit, :default}, 2)
    end
  end

  defp count_since(name, user_id, cutoff) do
    :ets.select_count(name, [
      {{{:request, user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}
    ])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp read_limits(path) do
    with {:ok, terms} <- consult(path),
         {:ok, limits} <- validate_limits(terms),
         :ok <- require_default(limits) do
      {:ok, limits}
    end
  end

  defp consult(path) do
    case :file.consult(path) do
      {:ok, terms} -> {:ok, terms}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp validate_limits(terms) do
    case Enum.find(terms, &(not valid_entry?(&1))) do
      nil -> {:ok, terms}
      entry -> {:error, {:invalid_entry, entry}}
    end
  end

  defp valid_entry?({user_id, limit}) when is_integer(limit) and limit >= 0 do
    is_binary(user_id) or is_integer(user_id) or user_id == :default
  end

  defp valid_entry?(_entry), do: false

  defp require_default(limits) do
    if List.keymember?(limits, :default, 0), do: :ok, else: {:error, :missing_default}
  end
end
