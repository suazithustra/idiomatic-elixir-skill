defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"alice": 600, "bob": 10}}

  A user not listed under `"users"` gets `"default"`. A missing or malformed file stops
  the limiter from starting, so the supervisor reports the problem at boot.

  ## How it works

  One ETS (Erlang Term Storage) table holds the loaded limits and one row per accepted
  request. Callers read and write the table from their own processes, so the owning
  GenServer is not a bottleneck. A request inserts its row first, then counts the user's
  rows from the last minute, and removes its own row if the count is over the limit. Two
  requests arriving together therefore cannot both slip under the limit. Under a burst
  over the limit, a request that is about to be refused is counted for a moment, so a
  concurrent request may be refused with it.

  The GenServer only creates the table and sweeps expired rows every
  `:sweep_interval` milliseconds so the table does not grow without limit.

  ## Starting it

  Add it to the supervision tree before anything that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        MyAppWeb.Endpoint
      ]

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - registered name, also the name of the ETS table. Defaults to
      `MyApp.RateLimiter`. Pass a different name to run a second instance, as a test does.
    * `:sweep_interval` - milliseconds between sweeps. Defaults to one minute.

  ## Calling it from a controller

      defmodule MyAppWeb.RateLimitPlug do
        import Plug.Conn

        def init(opts), do: opts

        def call(conn, _opts) do
          case MyApp.RateLimiter.check(to_string(conn.assigns.current_user.id)) do
            :ok ->
              conn

            {:error, :rate_limited} ->
              conn
              |> put_resp_header("retry-after", "60")
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  and in the controller: `plug MyAppWeb.RateLimitPlug`.

  ## Calling it from a background job

      defmodule MyApp.Workers.SyncAccount do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Accounts.sync(user_id)
            {:error, :rate_limited} -> {:snooze, 60}
          end
        end
      end
  """

  use GenServer

  defmodule Limits do
    @moduledoc false

    @enforce_keys [:default, :users]
    defstruct [:default, :users]

    @type t :: %__MODULE__{default: pos_integer(), users: %{String.t() => pos_integer()}}
  end

  @window_us :timer.minutes(1) * 1000
  @sweep_interval :timer.minutes(1)

  @type user_id :: String.t()

  @doc """
  Starts the limiter and loads the limits file.

  See the module documentation for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)
    sweep_interval = Keyword.get(opts, :sweep_interval, @sweep_interval)

    GenServer.start_link(__MODULE__, {name, config_path, sweep_interval}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is within the user's limit.

  A refused request is not counted against the user.

  ## Examples

      MyApp.RateLimiter.check("alice")
      #=> :ok

      MyApp.RateLimiter.check("bob")
      #=> {:error, :rate_limited}
  """
  @spec check(GenServer.name(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) when is_binary(user_id) do
    limit = limit_for(name, user_id)
    now = System.monotonic_time(:microsecond)
    row_key = {user_id, now, :erlang.unique_integer([:monotonic])}

    :ets.insert(name, {row_key})

    if count_since(name, user_id, now - @window_us) <= limit do
      :ok
    else
      :ets.delete(name, row_key)
      {:error, :rate_limited}
    end
  end

  defp limit_for(name, user_id) do
    [{:limits, limits}] = :ets.lookup(name, :limits)
    Map.get(limits.users, user_id, limits.default)
  end

  defp count_since(name, user_id, cutoff) do
    match_spec = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(name, match_spec)
  end

  @impl true
  def init({name, config_path, sweep_interval}) do
    with {:ok, limits} <- load_limits(config_path) do
      :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
      :ets.insert(name, {:limits, limits})
      Process.send_after(self(), :sweep, sweep_interval)

      {:ok, %{table: name, sweep_interval: sweep_interval}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:microsecond) - @window_us
    :ets.select_delete(state.table, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, state.sweep_interval)

    {:noreply, state}
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- read_file(config_path),
         {:ok, decoded} <- decode_json(contents) do
      parse_limits(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:stop, {:cannot_read_limits, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:stop, {:invalid_limits_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default, "users" => users})
       when is_integer(default) and default > 0 and is_map(users) do
    if Enum.all?(users, &valid_user_limit?/1) do
      {:ok, %Limits{default: default, users: users}}
    else
      {:stop, {:invalid_limits, :users}}
    end
  end

  defp parse_limits(_decoded), do: {:stop, :invalid_limits}

  defp valid_user_limit?({_user_id, limit}), do: is_integer(limit) and limit > 0
end
