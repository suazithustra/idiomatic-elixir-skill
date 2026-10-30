defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling 60-second window.

  N comes from a JSON file that is read once when the limiter starts:

      {"default": 30, "limits": {"42": 100, "7": 5}}

  `"default"` applies to users that are not listed under `"limits"`. The keys
  under `"limits"` are user IDs as strings. `check/2` converts the ID it is
  given with `to_string/1`, so integer IDs match.

  ## Starting

  Add the limiter to the supervision tree with the path to the file. Changing
  the file takes effect after a restart.

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  ## Checking

      case MyApp.RateLimiter.check(user.id) do
        :ok -> do_work()
        {:error, :rate_limited} -> reject()
      end

  ## How it works

  Each accepted request is one row in a public ETS table, keyed by user ID,
  time and a unique integer. `check/2` inserts its row before it counts the
  user's rows from the last minute. Inserting first means two concurrent
  requests cannot both read the same count and both pass. A row that pushes
  the count over the limit is deleted again. A sweep every minute removes rows
  older than the window.
  """

  use GenServer

  @window_ms :timer.minutes(1)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON file of limits.
    * `:name` - atom used to register the process and name its ETS table.
      Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Counts one request for `user_id` and returns `:ok` if it is within the
  user's limit, or `{:error, :rate_limited}` if the user has already used
  their requests for the last minute.

  Every `:ok` counts toward the limit, so call this once per unit of work.
  """
  @spec check(term(), atom()) :: :ok | {:error, :rate_limited}
  def check(user_id, name \\ __MODULE__) do
    key = to_string(user_id)
    limit = limit_for(key, name)
    now = System.monotonic_time(:millisecond)
    row = {key, now, :erlang.unique_integer([:monotonic, :positive])}

    :ets.insert(name, {row})

    if count_recent(name, key, now) > limit do
      :ets.delete(name, row)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    :persistent_term.put({__MODULE__, name}, read_limits!(config_path))

    table_options = [
      :named_table,
      :public,
      :ordered_set,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(name, table_options)
    schedule_sweep()
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp limit_for(key, name) do
    %{default: default, limits: limits} = :persistent_term.get({__MODULE__, name})
    Map.get(limits, key, default)
  end

  defp count_recent(name, key, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{key, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp read_limits!(config_path) do
    %{"default" => default, "limits" => limits} =
      config_path
      |> File.read!()
      |> JSON.decode!()

    Enum.each([default | Map.values(limits)], &validate_limit!/1)

    %{default: default, limits: limits}
  end

  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(limit) do
    raise ArgumentError, "expected a positive integer rate limit, got: #{inspect(limit)}"
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end
end
