defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  Limits come from a term file read once when the limiter starts. The file
  holds one map ending in a period. `:default` applies to every user not
  listed under `:users`:

      \#{default => 60, users => \#{42 => 300}}.

  Start the limiter in the supervision tree, passing the file path:

      children = [
        {MyApp.RateLimiter, config_path: Application.app_dir(:my_app, "priv/rate_limits.term")}
      ]

  Any code that is about to do limited work calls `check/1` first. A
  controller answers with a 429 response:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter
        alias MyApp.Reports

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              report = Reports.generate!(conn.assigns.current_user, params)
              json(conn, %{id: report.id})

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  A background job returns an error so the job system retries it later:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Exports.run(user_id)
          {:error, :rate_limited} -> {:snooze, 60}
        end
      end

  State lives in memory. A restart of the limiter forgets the requests it
  counted.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval :timer.seconds(10)
  @table __MODULE__.Windows
  @config_key {__MODULE__, :config}

  @doc """
  Records one request by `user_id` and returns `:ok` if it is within the
  user's limit.

  Returns `{:error, :rate_limited}` when the user has already used their limit
  in the last minute. The refused request is not counted.

  ## Examples

      :ok = MyApp.RateLimiter.check(user.id)
  """
  @spec check(term()) :: :ok | {:error, :rate_limited}
  def check(user_id) do
    row = {user_id, System.unique_integer([:monotonic, :positive])}
    now = System.monotonic_time(:millisecond)

    # Insert before counting so that concurrent requests see each other. An
    # admitted request stays in the table until it leaves the window, so a
    # request that counts after N admitted ones sees N + 1 rows and is refused.
    # Reading a list of timestamps, checking it, then writing it back would let
    # concurrent requests all see the same count.
    :ets.insert(@table, {row, now})

    if count_in_window(user_id, now) <= limit_for(user_id) do
      :ok
    else
      :ets.delete(@table, row)
      {:error, :rate_limited}
    end
  end

  @doc """
  Starts the limiter and loads its configuration.

  ## Options

    * `:config_path` - required. Path to the term file described in the
      module documentation.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config_path), name: __MODULE__)
  end

  @impl true
  def init(config_path) do
    case read_config(config_path) do
      {:ok, config} ->
        :persistent_term.put(@config_key, config)
        :ets.new(@table, [:named_table, :public, :ordered_set, write_concurrency: true])
        schedule_sweep()
        {:ok, nil}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp count_in_window(user_id, now) do
    cutoff = now - @window_ms
    :ets.select_count(@table, [{{{user_id, :_}, :"$1"}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(user_id) do
    %{default: default, users: users} = :persistent_term.get(@config_key)
    Map.get(users, user_id, default)
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp read_config(path) do
    case :file.consult(path) do
      {:ok, [config]} -> validate_config(config)
      {:ok, _terms} -> {:error, :expected_one_term}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_config(%{default: default, users: users}) when is_map(users) do
    if positive_integer?(default) and Enum.all?(users, &valid_user_limit?/1) do
      {:ok, %{default: default, users: users}}
    else
      {:error, :invalid_limit}
    end
  end

  defp validate_config(config), do: {:error, {:invalid_config, config}}

  defp valid_user_limit?({_user_id, limit}), do: positive_integer?(limit)

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
