defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  Per-user limits come from a JSON file that is read once, when the process
  starts. Example file:

      {"default": 60, "users": {"42": 300, "17": 10}}

  `default` applies to every user not listed in `users`. Every value must be a
  positive integer. To change a limit, edit the file and restart the process.

  ## Starting

  Add the limiter to the supervision tree:

      children = [
        {MyApp.RateLimiter, config_path: "config/rate_limits.json"}
      ]

  When `:config_path` is not given, the path comes from
  `Application.get_env(:my_app, :rate_limit_config_path)`. If the file is
  missing or invalid, the process stops at start with
  `{:invalid_rate_limit_config, reason}`, so the application fails at boot.

  ## Callers

  Call `hit/1` before doing the work. Each allowed call counts against the
  user's limit, so call it once per request.

  Controller:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          user = conn.assigns.current_user

          case MyApp.RateLimiter.hit(user.id) do
            {:ok, _remaining} ->
              report = MyApp.Reports.create_report!(user, params)
              json(conn, %{id: report.id})

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", to_string(div(retry_after_ms + 999, 1000)))
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  Background job (Oban-style worker, which can reschedule a job with `{:snooze, seconds}`):

      defmodule MyApp.Workers.ExportWorker do
        use Oban.Worker, queue: :exports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id, "export" => export}}) do
          case MyApp.RateLimiter.hit(user_id) do
            {:ok, _remaining} ->
              MyApp.Exports.run(user_id, export)

            {:error, {:rate_limited, retry_after_ms}} ->
              {:snooze, div(retry_after_ms + 999, 1000)}
          end
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.minutes(1)

  @typedoc false
  @type config :: %{default: pos_integer(), users: %{String.t() => pos_integer()}}

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - path to the JSON limits file. Defaults to
      `Application.get_env(:my_app, :rate_limit_config_path)`.
    * `:name` - registered name. Defaults to `#{inspect(__MODULE__)}`. Pass a
      different name to run a second instance, for example in tests.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    config_path =
      Keyword.get_lazy(opts, :config_path, fn ->
        Application.get_env(:my_app, :rate_limit_config_path)
      end)

    GenServer.start_link(__MODULE__, config_path, name: name)
  end

  @doc """
  Records one request for `user_id` if the user is under their limit.

  Returns `{:ok, remaining}`, where `remaining` is how many more requests the
  user may make in the current window. Returns
  `{:error, {:rate_limited, retry_after_ms}}` when the limit is reached, where
  `retry_after_ms` is how long until the next request would be allowed.
  Rejected requests are not recorded, so retrying early does not extend the wait.

  Integer and string IDs for the same user count together, because the
  limits file uses string keys.
  """
  @spec hit(integer() | String.t(), GenServer.server()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, pos_integer()}}
  def hit(user_id, server \\ __MODULE__)
      when is_integer(user_id) or is_binary(user_id) do
    GenServer.call(server, {:hit, to_string(user_id)})
  end

  @impl true
  def init(config_path) do
    case load_config(config_path) do
      {:ok, config} ->
        schedule_sweep()
        {:ok, %{config: config, hits: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_rate_limit_config, reason}}
    end
  end

  @impl true
  def handle_call({:hit, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = limit_for(state.config, key)
    recent = recent_hits(Map.get(state.hits, key, []), now)
    count = length(recent)

    if count < limit do
      hits = Map.put(state.hits, key, [now | recent])
      {:reply, {:ok, limit - count - 1}, %{state | hits: hits}}
    else
      hits = Map.put(state.hits, key, recent)
      retry_after = retry_after_ms(recent, limit, now)
      {:reply, {:error, {:rate_limited, retry_after}}, %{state | hits: hits}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    hits =
      for {key, stamps} <- state.hits,
          recent = recent_hits(stamps, now),
          recent != [],
          into: %{},
          do: {key, recent}

    schedule_sweep()
    {:noreply, %{state | hits: hits}}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp limit_for(%{users: users, default: default}, key) do
    Map.get(users, key, default)
  end

  # Hits are stored newest first, so the expired ones are at the end of the list.
  defp recent_hits(stamps, now) do
    cutoff = now - @window_ms
    Enum.take_while(stamps, &(&1 > cutoff))
  end

  # The request is allowed again once enough hits leave the window. `recent` has
  # at least `limit` entries, and the hit at index `limit - 1` is the last one that
  # must expire before the count drops below the limit.
  defp retry_after_ms(recent, limit, now) do
    blocking_hit = Enum.at(recent, limit - 1)
    blocking_hit + @window_ms - now
  end

  defp load_config(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode(contents) do
      validate(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:invalid_json, error}}
    end
  end

  defp validate(%{"default" => default, "users" => users}) when is_map(users) do
    with :ok <- validate_limit("default", default),
         :ok <- validate_user_limits(users) do
      {:ok, %{default: default, users: users}}
    end
  end

  defp validate(_decoded), do: {:error, :missing_default_or_users}

  defp validate_user_limits(users) do
    case Enum.find(users, fn {_user, limit} -> not positive_integer?(limit) end) do
      nil -> :ok
      {user, _limit} -> {:error, {:invalid_limit, user}}
    end
  end

  defp validate_limit(user, limit) do
    if positive_integer?(limit), do: :ok, else: {:error, {:invalid_limit, user}}
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
