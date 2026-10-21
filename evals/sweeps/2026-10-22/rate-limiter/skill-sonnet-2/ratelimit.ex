defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limit: each user may make at most N requests in any rolling minute.

  N comes from a JSON file read once when the limiter starts:

      {"default": 60, "users": {"42": 300, "1001": 10}}

  Users not listed under `"users"` get `"default"`. User IDs are integers or strings;
  the file always spells them as strings.

  Each allowed request is stored as one row in a public ETS (Erlang Term Storage) table
  owned by this process. Callers read and write the table from their own processes, so
  checks never queue behind a single process.

  ## Starting

  Add it to the supervision tree in `MyApp.Application`, before the endpoint and any job
  runner that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_file)},
        MyAppWeb.Endpoint
      ]

  with `config :my_app, rate_limit_file: "priv/rate_limits.json"` in `config/runtime.exs`.
  If the file is missing or invalid, the limiter fails to start and so does the application.

  ## Calling it

  A controller, using `action_fallback` to turn the error into a 429 response:

      def create(conn, params) do
        with :ok <- MyApp.RateLimiter.check(conn.assigns.current_user.id),
             {:ok, report} <- Reports.create(params) do
          json(conn, report)
        end
      end

      # in the fallback controller
      def call(conn, {:error, :rate_limited}) do
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limit exceeded"})
      end

  A background job (an Oban worker, for example):

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> do_work(user_id)
          {:error, :rate_limited} -> {:snooze, 30}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter and loads its limits from the file given as `:config_path`.

  ## Options

    * `:config_path` - path to the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:config_path, name: __MODULE__])
    config_path = Keyword.fetch!(opts, :config_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed. Returns `{:error, :rate_limited}` when the
  user already made their limit of requests in the last minute; a rejected request does
  not count against the user.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) when is_integer(user_id) or is_binary(user_id) do
    now = System.monotonic_time(:millisecond)
    limit = limit_for(name, user_id)
    row_key = {user_id, now, :erlang.unique_integer([:monotonic])}

    # Insert first, then count: a lookup-then-insert would let concurrent
    # requests all read the same count and exceed the limit.
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
    case load_limits(config_path) do
      {:ok, limits} ->
        :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
        :ets.insert(name, {:limits, limits})
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, config_path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp limit_for(name, user_id) do
    [{:limits, %{default: default, users: users}}] = :ets.lookup(name, :limits)
    Map.get(users, to_string(user_id), default)
  end

  defp count_since(name, user_id, cutoff) do
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp load_limits(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) when is_integer(default) and default > 0 do
    users = Map.get(decoded, "users", %{})

    if is_map(users) and Enum.all?(users, fn {_user_id, limit} -> valid_limit?(limit) end) do
      {:ok, %{default: default, users: users}}
    else
      {:error, {:invalid_field, "users"}}
    end
  end

  defp parse_limits(%{"default" => _default}), do: {:error, {:invalid_field, "default"}}
  defp parse_limits(_decoded), do: {:error, {:missing_field, "default"}}

  defp valid_limit?(limit), do: is_integer(limit) and limit > 0
end
