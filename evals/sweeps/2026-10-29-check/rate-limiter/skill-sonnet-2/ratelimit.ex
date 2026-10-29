defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any
  rolling minute.

  N comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"42": 600, "1001": 10}}

  A user not listed under `"users"` gets `"default"`. Changing the file
  takes effect after the limiter restarts.

  Every request is stored in an ETS (Erlang Term Storage) table owned by
  this process. Callers write to and read from the table in their own
  processes, so checks do not queue behind one another. A check first
  records the request, then counts the user's requests in the last
  minute, and removes its own record if the count is over the limit.
  Two concurrent checks near the limit may both be refused, but they can
  never both be allowed past it.

  ## Starting it

  Add it to the supervision tree before anything that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint
      ]

  ## Calling it from a controller

      plug :rate_limit when action in [:create, :update]

      defp rate_limit(conn, _opts) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            conn

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> put_view(json: MyAppWeb.ErrorJSON)
            |> render(:"429")
            |> halt()
        end
      end

  ## Calling it from a background job (Oban)

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @default_sweep_interval_ms :timer.minutes(1)

  @type user_id :: String.t() | integer()

  @doc """
  Starts the limiter and its table.

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - process and table name, an atom. Defaults to
      `#{inspect(__MODULE__)}`.
    * `:sweep_interval` - milliseconds between removals of records older
      than the window. Defaults to one minute.

  The start fails if the file cannot be read or is not valid.
  """
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [
        :config_path,
        name: __MODULE__,
        sweep_interval: @default_sweep_interval_ms
      ])

    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)
    sweep_interval = Keyword.fetch!(opts, :sweep_interval)

    GenServer.start_link(__MODULE__, {name, config_path, sweep_interval}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit, or
  `{:error, :rate_limited}` when they are not. A refused request is not
  counted against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = to_string(user_id)
    now = System.monotonic_time(:millisecond)
    record = {user, now, :erlang.unique_integer([:monotonic])}

    true = :ets.insert(name, {record})

    if count_in_window(name, user, now) <= limit_for(name, user) do
      :ok
    else
      :ets.delete(name, record)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path, sweep_interval}) do
    case read_config(config_path) do
      {:ok, config} ->
        table_options = [
          :named_table,
          :public,
          :ordered_set,
          read_concurrency: true,
          write_concurrency: true
        ]

        :ets.new(name, table_options)
        # The limits never change while the process lives and every caller
        # reads them, so they live in :persistent_term rather than the table.
        :persistent_term.put({__MODULE__, name}, config)
        Process.send_after(self(), :sweep, sweep_interval)

        {:ok, %{name: name, sweep_interval: sweep_interval}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep(state.name)
    Process.send_after(self(), :sweep, state.sweep_interval)

    {:noreply, state}
  end

  defp count_in_window(name, user, now) do
    cutoff = now - @window_ms
    match_spec = [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]

    :ets.select_count(name, match_spec)
  end

  defp limit_for(name, user) do
    config = :persistent_term.get({__MODULE__, name})

    Map.get(config.users, user, config.default)
  end

  defp sweep(name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    match_spec = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]

    :ets.select_delete(name, match_spec)
  end

  defp read_config(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      build_config(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp build_config(%{"default" => default, "users" => users})
       when is_integer(default) and default > 0 and is_map(users) do
    if Enum.all?(users, fn {_user, limit} -> is_integer(limit) and limit > 0 end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_user_limit}
    end
  end

  defp build_config(_decoded), do: {:error, :invalid_config}
end
