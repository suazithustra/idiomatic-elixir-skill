defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to a set number of requests per rolling minute.

  Requests are counted in an ETS (Erlang Term Storage) table. Callers read and
  write that table from their own process through `check/2`, so the limiter
  process is never a bottleneck. It only owns the table and removes expired rows.

  ## Configuration file

  Limits come from a JSON file that is read once, when the limiter starts.
  `"default"` applies to every user with no entry under `"users"`, and both keys
  are required. A limit is a non-negative integer, and 0 blocks the user. The
  limiter refuses to start if the file is missing or invalid, so the application
  cannot run with limits nobody chose.

      {
        "default": 60,
        "users": {
          "42": 600,
          "1337": 10
        }
      }

  ## Starting the limiter

  Add it to the supervision tree in `MyApp.Application`, ahead of everything that
  calls it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter, path: Application.app_dir(:my_app, "priv/rate_limits.json")},
        {Oban, Application.fetch_env!(:my_app, Oban)},
        MyAppWeb.Endpoint
      ]

      Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)

  ## Calling it from a controller

  `{:error, :rate_limited}` passes through `with` to the fallback controller, so
  every controller shares one 429 response:

      defmodule MyAppWeb.ReportController do
        use MyAppWeb, :controller

        action_fallback MyAppWeb.FallbackController

        def create(conn, params) do
          user = conn.assigns.current_user

          with :ok <- MyApp.RateLimiter.check(user.id),
               {:ok, report} <- MyApp.Reports.create_report(user, params) do
            render(conn, :show, report: report)
          end
        end
      end

      defmodule MyAppWeb.FallbackController do
        use MyAppWeb, :controller

        # A slot frees up within the one-minute window.
        @retry_after_seconds "60"

        def call(conn, {:error, :rate_limited}) do
          conn
          |> put_resp_header("retry-after", @retry_after_seconds)
          |> send_resp(:too_many_requests, "")
        end
      end

  ## Calling it from a background job

  A limited job waits and runs again instead of counting as a failure:

      defmodule MyApp.Workers.ExportWorker do
        use Oban.Worker, queue: :exports

        # A slot frees up within the one-minute window.
        @retry_after_seconds 60

        @impl Oban.Worker
        def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
          case MyApp.RateLimiter.check(user_id) do
            :ok -> MyApp.Exports.run(user_id)
            {:error, :rate_limited} -> {:snooze, @retry_after_seconds}
          end
        end
      end

  ## Known limitations

  Counts are kept per node, so behind a load balancer a user can make N requests
  on each node. Counts are lost if the limiter restarts. While it is down, `check/2`
  raises `ArgumentError`, so callers fail rather than run unchecked. A change to the
  file takes effect at the next start.
  """

  use GenServer

  @type user_id :: String.t() | integer()

  @window_ms :timer.minutes(1)

  @doc """
  Starts the limiter and reads the limits from the configuration file.

  ## Options

    * `:path` - path of the JSON configuration file. Required.
    * `:name` - atom naming the process and its table, so a test can start its
      own instance. Defaults to `MyApp.RateLimiter`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:path, name: __MODULE__])
    name = opts[:name]
    GenServer.start_link(__MODULE__, {Keyword.fetch!(opts, :path), name}, name: name)
  end

  @doc """
  Takes one of the user's request slots for the next minute, if one is free.

  Returns `:ok` when the work may go ahead. Returns `{:error, :rate_limited}` when
  it may not, which uses no slot, so call this once for each piece of work, right
  before doing it.

  `42` and `"42"` are the same user, because the configuration file can only name
  users with strings.

  ## Examples

      iex> path = Path.join(System.tmp_dir!(), "rate_limits_doctest.json")
      iex> File.write!(path, ~s({"default": 1, "users": {"alice": 2}}))
      iex> {:ok, _pid} = MyApp.RateLimiter.start_link(path: path, name: :limiter_doctest)
      iex> MyApp.RateLimiter.check(:limiter_doctest, "bob")
      :ok
      iex> MyApp.RateLimiter.check(:limiter_doctest, "bob")
      {:error, :rate_limited}
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id)

  def check(name, user_id) when is_integer(user_id), do: check(name, Integer.to_string(user_id))

  def check(name, user_id) when is_binary(user_id) do
    now = System.monotonic_time(:millisecond)
    # The unique integer keeps two requests in the same millisecond on separate rows.
    key = {user_id, now, System.unique_integer()}

    # Insert before counting: of two racing requests, the later insert counts the
    # earlier one, so the limit holds. At worst both lose the last free slot.
    :ets.insert(name, {key})

    if count_requests(name, user_id, now) > limit_for(name, user_id) do
      # A refused request must not hold a slot, or a client that keeps retrying
      # would stay blocked after its earlier requests leave the window.
      :ets.delete(name, key)
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @impl true
  def init({path, name}) when is_binary(path) and is_atom(name) do
    # Not in handle_continue/2: callers do not go through this process, so the limits
    # must be in place before start_link/1 returns and the supervisor starts them.
    case load_limits(path) do
      {:ok, limits} ->
        :persistent_term.put({__MODULE__, name}, limits)
        # Rows sort by user ID, so a count for one user skips the rest of the table.
        :ets.new(name, [:named_table, :public, :ordered_set, write_concurrency: true])
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, {:invalid_rate_limits, path, reason}}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  defp count_requests(name, user_id, now) do
    cutoff = now - @window_ms
    :ets.select_count(name, [{{{user_id, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp limit_for(name, user_id) do
    limits = :persistent_term.get({__MODULE__, name})
    Map.get(limits.users, user_id, limits.default)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @window_ms)

  defp load_limits(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      parse_limits(decoded)
    end
  end

  defp parse_limits(%{"default" => default, "users" => %{} = users}) do
    entries = [{"default", default} | Map.to_list(users)]

    case Enum.reject(entries, &valid_limit?/1) do
      [] -> {:ok, %{default: default, users: users}}
      invalid -> {:error, {:invalid_limits, invalid}}
    end
  end

  defp parse_limits(_decoded), do: {:error, :invalid_format}

  defp valid_limit?({_owner, limit}), do: is_integer(limit) and limit >= 0
end
