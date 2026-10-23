defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any rolling minute.

  N for each user comes from a JSON file read once when the limiter starts:

      {"default": 60, "users": {"user-17": 600, "user-42": 10}}

  Users not listed under `"users"` get `"default"`. User IDs are strings (convert
  integer IDs with `to_string/1`). A file that cannot be read, is not valid JSON, or has a missing or
  non-positive limit stops the limiter at startup.

  Requests are stored in an ETS (Erlang Term Storage) table owned by the
  limiter process, and `check/2` runs in the caller's process, so callers do not
  queue behind the owner. A check inserts a row for the request, counts the
  user's rows from the last minute, and deletes its own row if the user is over
  the limit. Rejected requests therefore do not count against the user.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before the endpoint and
  any job processor that calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  with, in `config/runtime.exs`:

      config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

  ## Calling it

  From a Phoenix controller, as a plug:

      defmodule MyAppWeb.OrderController do
        use MyAppWeb, :controller

        plug :rate_limit when action in [:create]

        def create(conn, params) do
          # ...
        end

        defp rate_limit(conn, _opts) do
          case MyApp.RateLimiter.check(to_string(conn.assigns.current_user.id)) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              conn
              |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms, 1000) + 1))
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  From a background job (an Oban worker here):

      defmodule MyApp.Workers.SyncAccount do
        use Oban.Worker

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Accounts.sync(user_id)
            {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
          end
        end
      end

  ## Options

    * `:config_path` - path of the JSON limits file. Required.
    * `:name` - name of the process and of its ETS table. Defaults to
      `#{inspect(__MODULE__)}`. Pass the same name to `check/2`.
    * `:sweep_interval` - milliseconds between deletions of expired rows.
      Defaults to one minute.
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @default_sweep_interval :timer.minutes(1)

  @type user_id :: String.t()

  @doc """
  Starts the limiter. See the module documentation for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts =
      Keyword.validate!(opts, [
        :config_path,
        name: __MODULE__,
        sweep_interval: @default_sweep_interval
      ])

    config_path = Keyword.fetch!(opts, :config_path)

    GenServer.start_link(__MODULE__, {opts[:name], config_path, opts[:sweep_interval]},
      name: opts[:name]
    )
  end

  @doc """
  Records a request by `user_id` and reports whether it is within the user's limit.

  Returns `{:error, {:rate_limited, retry_after_ms}}` when the user already made
  their limit of requests in the last minute; `retry_after_ms` is the time until
  the oldest of those requests leaves the window. The rejected request is not recorded.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    limit = limit_for(name, user_id)

    request_key = {:request, user_id, now, :erlang.unique_integer([:monotonic])}
    true = :ets.insert(name, {request_key})

    recent = recent_request_times(name, user_id, now - @window_ms)

    if length(recent) <= limit do
      :ok
    else
      :ets.delete(name, request_key)
      {:error, {:rate_limited, Enum.min(recent) + @window_ms - now}}
    end
  end

  @impl true
  def init({name, config_path, sweep_interval}) do
    case load_limits(config_path) do
      {:ok, limits} ->
        table_options = [:named_table, :public, :ordered_set, write_concurrency: true]
        :ets.new(name, table_options)
        true = :ets.insert(name, limits)

        Process.send_after(self(), :sweep, sweep_interval)
        {:ok, %{name: name, sweep_interval: sweep_interval}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    delete_expired(state.name, System.monotonic_time(:millisecond) - @window_ms)

    Process.send_after(self(), :sweep, state.sweep_interval)
    {:noreply, state}
  end

  defp limit_for(name, user_id) do
    case :ets.lookup(name, {:limit, user_id}) do
      [{_key, limit}] -> limit
      [] -> :ets.lookup_element(name, :default_limit, 2)
    end
  end

  defp recent_request_times(name, user_id, cutoff) do
    match_spec = [{{{:request, user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [:"$1"]}]
    :ets.select(name, match_spec)
  end

  defp delete_expired(name, cutoff) do
    match_spec = [{{{:request, :_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(name, match_spec)
  end

  defp load_limits(config_path) do
    with {:ok, contents} <- read_file(config_path),
         {:ok, config} <- decode_json(contents),
         {:ok, default} <- parse_default(config),
         {:ok, users} <- parse_user_limits(config) do
      user_rows = Enum.map(users, fn {user_id, limit} -> {{:limit, user_id}, limit} end)
      {:ok, [{:default_limit, default} | user_rows]}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable_config, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = config} -> {:ok, config}
      {:ok, _other} -> {:error, :config_not_an_object}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_default(%{"default" => limit}) when is_integer(limit) and limit > 0 do
    {:ok, limit}
  end

  defp parse_default(_config), do: {:error, {:invalid_limit, "default"}}

  defp parse_user_limits(%{"users" => %{} = users}) do
    Enum.reduce_while(users, {:ok, []}, fn
      {user_id, limit}, {:ok, acc} when is_integer(limit) and limit > 0 ->
        {:cont, {:ok, [{user_id, limit} | acc]}}

      {user_id, _limit}, {:ok, _acc} ->
        {:halt, {:error, {:invalid_limit, user_id}}}
    end)
  end

  defp parse_user_limits(%{"users" => _other}), do: {:error, {:invalid_field, "users"}}
  defp parse_user_limits(_config), do: {:ok, []}
end
