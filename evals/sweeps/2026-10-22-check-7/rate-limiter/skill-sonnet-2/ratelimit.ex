defmodule MyApp.RateLimiter do
  @moduledoc """
  Per-user rate limiter: each user may make at most N requests in any
  rolling 60 seconds.

  N per user comes from a JSON file read once, when the limiter starts:

      {"default": 60, "users": {"42": 10, "1001": 600}}

  Users not listed under `"users"` get `"default"`. User IDs are matched by
  their string form.

  Every request is stored as one row in a public ETS table owned by this
  process. Callers record and count their own requests, so checks never queue
  behind the owner process; the owner only creates the tables and sweeps
  expired rows.

  ## Starting it

  Add it to the supervision tree in `MyApp.Application`, before anything that
  calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, limits_path: Application.fetch_env!(:my_app, :rate_limits_path)},
        MyAppWeb.Endpoint
      ]

  with, in `config/runtime.exs`:

      config :my_app, rate_limits_path: System.get_env("RATE_LIMITS_PATH", "priv/rate_limits.json")

  ## Calling it

  From a controller, using a plug:

      defmodule MyAppWeb.Plugs.RateLimit do
        @behaviour Plug

        import Plug.Conn

        @impl true
        def init(opts), do: opts

        @impl true
        def call(%{assigns: %{current_user: user}} = conn, _opts) do
          case MyApp.RateLimiter.check(user.id) do
            :ok ->
              conn

            {:error, {:rate_limited, retry_after_ms}} ->
              retry_after = to_string(div(retry_after_ms, 1000) + 1)

              conn
              |> put_resp_header("retry-after", retry_after)
              |> send_resp(429, "Too many requests")
              |> halt()
          end
        end
      end

  From a background job:

      def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> MyApp.Reports.generate(user_id)
          {:error, {:rate_limited, retry_after_ms}} -> {:snooze, div(retry_after_ms, 1000) + 1}
        end
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)
  @sweep_interval_ms :timer.seconds(30)

  @type user_id :: term()

  @doc """
  Starts the limiter and loads the limits file.

  ## Options

    * `:limits_path` - path of the JSON limits file. Required.
    * `:name` - registered name, also the name of the ETS tables. Defaults to
      `MyApp.RateLimiter`.
  """
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:limits_path, name: __MODULE__])
    limits_path = Keyword.fetch!(opts, :limits_path)
    name = Keyword.fetch!(opts, :name)

    GenServer.start_link(__MODULE__, {name, limits_path}, name: name)
  end

  @doc """
  Records a request by `user_id` and says whether it is allowed.

  Returns `:ok` when the user is within their limit, or
  `{:error, {:rate_limited, retry_after_ms}}` when it is not. A rejected
  request is not counted against the user.

  When many requests race at the limit, more than one may be rejected, but
  none is ever allowed beyond the limit.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, {:rate_limited, pos_integer()}}
  def check(name \\ __MODULE__, user_id) do
    now = System.monotonic_time(:millisecond)
    request_key = {user_id, now, make_ref()}
    :ets.insert(requests_table(name), {request_key})

    if count_since(name, user_id, now - @window_ms) > limit_for(name, user_id) do
      :ets.delete(requests_table(name), request_key)
      {:error, {:rate_limited, retry_after(name, user_id, now)}}
    else
      :ok
    end
  end

  @doc """
  Returns the number of requests per minute allowed for `user_id`.
  """
  @spec limit_for(atom(), user_id()) :: pos_integer()
  def limit_for(name \\ __MODULE__, user_id) do
    case :ets.lookup(limits_table(name), to_string(user_id)) do
      [{_user_id, limit}] -> limit
      [] -> :ets.lookup_element(limits_table(name), :default, 2)
    end
  end

  @impl true
  def init({name, limits_path}) do
    with {:ok, limits} <- load_limits(limits_path) do
      limits_options = [:named_table, :protected, :set, read_concurrency: true]
      limits_table = :ets.new(limits_table(name), limits_options)
      :ets.insert(limits_table, limits)

      requests_options = [:named_table, :public, :ordered_set, write_concurrency: true]
      :ets.new(requests_table(name), requests_options)

      schedule_sweep()
      {:ok, name}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    expired = [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}]
    :ets.select_delete(requests_table(name), expired)

    schedule_sweep()
    {:noreply, name}
  end

  # The user may retry when their oldest request still in the window expires.
  defp retry_after(name, user_id, now) do
    in_window = [{{{user_id, :"$1", :_}}, [{:>, :"$1", now - @window_ms}], [:"$1"]}]

    case :ets.select(requests_table(name), in_window) do
      [] -> 1
      timestamps -> max(Enum.min(timestamps) + @window_ms - now, 1)
    end
  end

  defp count_since(name, user_id, cutoff) do
    in_window = [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}]
    :ets.select_count(requests_table(name), in_window)
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
      {:error, reason} -> {:stop, {:limits_unreadable, path, reason}}
    end
  end

  defp decode_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:stop, {:limits_invalid_json, reason}}
    end
  end

  defp parse_limits(%{"default" => default} = decoded) when is_integer(default) and default > 0 do
    users = Map.get(decoded, "users", %{})

    if is_map(users) and Enum.all?(users, &valid_user_limit?/1) do
      {:ok, [{:default, default} | Map.to_list(users)]}
    else
      {:stop, {:limits_invalid, "users"}}
    end
  end

  defp parse_limits(_decoded), do: {:stop, {:limits_invalid, "default"}}

  defp valid_user_limit?({user_id, limit}) do
    is_binary(user_id) and is_integer(limit) and limit > 0
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp requests_table(name), do: name
  defp limits_table(name), do: :"#{name}.Limits"
end
