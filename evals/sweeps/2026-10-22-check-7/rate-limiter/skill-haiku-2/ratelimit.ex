defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user a fixed number of requests in any rolling one-minute window.

  The limit for each user comes from a config file, read when the limiter
  starts. The file holds Erlang terms, each ended with a period. The
  `{:default, n}` line sets the limit for users without their own line; every
  other line is `{user_id, n}`:

      {default, 60}.
      {42, 300}.
      {77, 10}.

  Only allowed requests are recorded. A denied request does not use up the
  budget, so a caller that retries after `retry_after` is not pushed further
  back by its own retries.

  ## Starting

  Add the limiter to the supervision tree with the path to the config file:

      children = [
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.terms")}
      ]

  ## Callers

  Controllers check before doing the work:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, params) do
          case RateLimiter.check(conn.assigns.current_user.id) do
            :ok ->
              render_report(conn, params)

            {:error, {:rate_limited, retry_after}} ->
              conn
              |> put_resp_header("retry-after", to_string(ceil(retry_after / 1000)))
              |> send_resp(:too_many_requests, "")
          end
        end
      end

  Background jobs check the same way and reschedule when the limit is hit:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> build_report(user_id)
          {:error, {:rate_limited, retry_after}} -> {:snooze, ceil(retry_after / 1000)}
        end
      end
  """

  use GenServer

  @window :timer.minutes(1)

  defguardp is_limit(value) when is_integer(value) and value > 0

  @doc """
  Starts the limiter and reads the limits from `:config_path`.

  ## Options

    * `:config_path` - required. Path to the limits file.
    * `:name` - registered name of the process. Defaults to `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, config_path, name: name)
  end

  @doc """
  Records a request for `user_id` if the user is under their limit.

  Returns `:ok` when the request is allowed. Otherwise returns
  `{:error, {:rate_limited, retry_after}}`, where `retry_after` is the number
  of milliseconds until the user's oldest recorded request leaves the window.
  """
  @spec check(GenServer.server(), term()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(server \\ __MODULE__, user_id) do
    GenServer.call(server, {:check, user_id})
  end

  @impl true
  def init(config_path) do
    # Read here, not in handle_continue/2, so a bad file fails the start.
    case load_config(config_path) do
      {:ok, config} ->
        schedule_sweep()
        {:ok, Map.put(config, :windows, %{})}

      {:error, reason} ->
        {:stop, {:invalid_config, reason}}
    end
  end

  @impl true
  def handle_call({:check, user_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits, user_id, state.default)
    timestamps = state.windows |> Map.get(user_id, []) |> recent(now)

    if length(timestamps) < limit do
      {:reply, :ok, put_timestamps(state, user_id, [now | timestamps])}
    else
      {:reply, {:error, {:rate_limited, retry_after(timestamps, now)}}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    windows =
      state.windows
      |> Map.new(fn {user_id, timestamps} -> {user_id, recent(timestamps, now)} end)
      |> Map.reject(fn {_user_id, timestamps} -> timestamps == [] end)

    schedule_sweep()
    {:noreply, %{state | windows: windows}}
  end

  defp load_config(path) do
    case :file.consult(path) do
      {:ok, terms} -> parse_config(terms)
      {:error, _reason} = error -> error
    end
  end

  defp parse_config(terms) do
    case Enum.split_with(terms, &match?({:default, _}, &1)) do
      {[{:default, default}], entries} -> build_config(default, entries)
      {_defaults, _entries} -> {:error, :default_must_appear_once}
    end
  end

  defp build_config(default, entries) do
    if is_limit(default) and Enum.all?(entries, &valid_entry?/1) do
      {:ok, %{default: default, limits: Map.new(entries)}}
    else
      {:error, :invalid_limit}
    end
  end

  defp valid_entry?({_user_id, limit}) when is_limit(limit), do: true
  defp valid_entry?(_entry), do: false

  defp recent(timestamps, now) do
    Enum.take_while(timestamps, &(&1 > now - @window))
  end

  defp retry_after(timestamps, now) do
    List.last(timestamps) + @window - now
  end

  defp put_timestamps(state, user_id, timestamps) do
    %{state | windows: Map.put(state.windows, user_id, timestamps)}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window)
  end
end
