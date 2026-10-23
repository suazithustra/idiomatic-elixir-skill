defmodule RateLimit do
  @moduledoc """
  Per-user rate limiter. Each user may make at most N requests in any rolling
  60-second window. N is read per user from a JSON file when the limiter starts.

  State is kept in memory on the node that runs the limiter. Limits are not
  shared across nodes.

  ## Configuration file

  A JSON object. `"default"` is required. `"users"` is optional and maps user
  IDs (as strings) to their own limit. Users not listed get `"default"`.

      {
        "default": 60,
        "users": {
          "42": 300,
          "97": 10
        }
      }

  ## Starting

  Add it to the supervision tree, for example in `MyApp.Application`:

      children = [
        {RateLimit, config_path: Application.app_dir(:my_app, "priv/rate_limits.json")}
      ]

  The file is read once, in `init/1`. If it is missing or invalid, startup fails.
  Editing the file requires a restart.

  ## Callers

  `check/1` records one request if the user is under their limit. The request is
  counted even if the work that follows later fails.

  Controller:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        def create(conn, params) do
          case RateLimit.check(conn.assigns.current_user.id) do
            :ok ->
              report = Reports.generate!(params)
              json(conn, report)

            {:error, :rate_limited, retry_after_ms} ->
              seconds = div(retry_after_ms + 999, 1000)

              conn
              |> put_resp_header("retry-after", Integer.to_string(seconds))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  Background job (Oban assumed):

      defmodule MyApp.Workers.Export do
        use Oban.Worker, queue: :exports

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
          case RateLimit.check(user_id) do
            :ok ->
              Exports.run(args)

            {:error, :rate_limited, retry_after_ms} ->
              {:snooze, div(retry_after_ms + 999, 1000)}
          end
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms 60_000

  ## Client API

  @doc """
  Starts the limiter. Options:

    * `:config_path` (required) - path to the JSON limits file
    * `:name` - registered name, defaults to `#{inspect(__MODULE__)}`
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records one request for `user_id` if it is under the user's limit.

  Returns `:ok`, or `{:error, :rate_limited, retry_after_ms}` where
  `retry_after_ms` is the wait until the next request would be allowed.
  `user_id` may be an integer or a string.
  """
  @spec check(term(), GenServer.server()) :: :ok | {:error, :rate_limited, pos_integer()}
  def check(user_id, server \\ __MODULE__) do
    GenServer.call(server, {:check, to_string(user_id)})
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :config_path)

    case load_limits(path) do
      {:ok, limits} ->
        Process.send_after(self(), :sweep, @sweep_interval_ms)
        {:ok, %{limits: limits, hits: %{}}}

      {:error, reason} ->
        {:stop, {:invalid_config, path, reason}}
    end
  end

  @impl true
  def handle_call({:check, user}, _from, state) do
    now = System.monotonic_time(:millisecond)
    limit = Map.get(state.limits.users, user, state.limits.default)
    window = recent(Map.get(state.hits, user, []), now)

    if length(window) < limit do
      {:reply, :ok, put_hits(state, user, [now | window])}
    else
      {:reply, {:error, :rate_limited, retry_after(window, now)}, put_hits(state, user, window)}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    # Drop users whose hits have all expired, so memory does not grow without bound.
    now = System.monotonic_time(:millisecond)

    hits =
      state.hits
      |> Enum.map(fn {user, times} -> {user, recent(times, now)} end)
      |> Enum.reject(fn {_user, times} -> times == [] end)
      |> Map.new()

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, %{state | hits: hits}}
  end

  ## Helpers

  # Timestamps are kept newest first. Keep only those inside the rolling window.
  defp recent(times, now), do: Enum.filter(times, &(&1 > now - @window_ms))

  defp put_hits(state, user, times), do: %{state | hits: Map.put(state.hits, user, times)}

  # The oldest hit in the window is the last element. Its expiry is the next free slot.
  defp retry_after([], _now), do: @window_ms
  defp retry_after(window, now), do: max(List.last(window) + @window_ms - now, 1)

  defp load_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- decode(contents) do
      parse_limits(decoded)
    else
      {:error, reason} when is_atom(reason) -> {:error, {:file, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, error} -> {:error, {:json, Exception.message(error)}}
    end
  end

  defp parse_limits(%{"default" => default} = config) when is_integer(default) and default >= 0 do
    users = Map.get(config, "users", %{})

    cond do
      not is_map(users) ->
        {:error, ~s("users" must be an object)}

      not Enum.all?(users, fn {_id, n} -> is_integer(n) and n >= 0 end) ->
        {:error, "every user limit must be a non-negative integer"}

      true ->
        {:ok, %{default: default, users: users}}
    end
  end

  defp parse_limits(_other) do
    {:error, ~s(expected an object with a non-negative integer "default")}
  end
end
