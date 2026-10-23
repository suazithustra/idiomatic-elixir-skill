defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling minute.

  Start it in the supervision tree, pointing it at a configuration file:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.exs")}
      ]

  The file is Elixir code, evaluated once when the process starts, that returns a map:

      %{default: 60, users: %{42 => 300, "svc-billing" => 1000}}

  `:default` is the limit for every user not listed under `:users`. Like
  `config/*.exs`, the file is trusted code, so only the deploy process should
  write it. A change takes effect after a restart.

  Requests are counted in an ETS table owned by this process. `check/2` runs in
  the caller's process and never waits on the limiter, so controllers and jobs
  do not queue behind each other.

  ## Callers

  A controller answers 429 when the user is over the limit:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok -> create_report(conn, params)
          {:error, :rate_limited} -> send_resp(conn, 429, "Too many requests")
        end
      end

  A background job uses the same check and returns the error to its job system,
  which retries it later.
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @type user_id :: integer() | binary()

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required, the path to the limits file
    * `:name` - the registered name, which is also the ETS table name.
      Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records a request for `user_id` and returns `:ok` if it is within the limit.

  A request over the limit is not recorded, so rejected attempts do not use up
  the user's allowance.
  """
  @spec check(user_id()) :: :ok | {:error, :rate_limited}
  @spec check(GenServer.name(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id)
      when is_integer(user_id) or is_binary(user_id) do
    now = now_ms()
    # Insert before counting. The last of several concurrent requests to count
    # sees every row inserted before its count, so the limit holds without a lock.
    key = {user_id, now, :erlang.unique_integer([:monotonic])}
    :ets.insert(name, {key})

    if count_recent(name, user_id, now) > limit_for(name, user_id) do
      :ets.delete(name, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({name, config_path}) do
    config = config_path |> read_config!() |> validate_config!()
    :persistent_term.put({__MODULE__, name}, config)

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
    # Requests older than the window no longer count, so removing them is safe.
    cutoff = now_ms() - @window
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp count_recent(name, user_id, now) do
    cutoff = now - @window
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    %{default: default, users: users} = :persistent_term.get({__MODULE__, name})
    Map.get(users, user_id, default)
  end

  defp read_config!(path) do
    {config, _binding} = Code.eval_file(path)
    config
  end

  defp validate_config!(%{default: default, users: users} = config) do
    if Enum.all?([default | Map.values(users)], &(is_integer(&1) and &1 > 0)) do
      config
    else
      raise ArgumentError, "rate limits must be positive integers, got: #{inspect(config)}"
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
