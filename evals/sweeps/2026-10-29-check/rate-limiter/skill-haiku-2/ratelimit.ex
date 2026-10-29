defmodule MyApp.RateLimiter do
  @moduledoc """
  Allows each user a fixed number of requests in any rolling minute.

  The limit for each user comes from a configuration file that is read once,
  when the limiter starts. The file is an Elixir expression that evaluates to a
  map from user ID to limit, like the files under `config/`:

      %{
        "user-1" => 60,
        42 => 300
      }

  Callers run `check/2` before doing the work. An allowed request is counted;
  a rejected one is not. A user missing from the file is rejected.

  ## Starting it

  Add the limiter to the supervision tree:

      children = [
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.terms")}
      ]

  ## Calling it

  From a controller:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            do_create(conn, params)

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> text("Too many requests")

          {:error, :unknown_user} ->
            send_resp(conn, :forbidden, "")
        end
      end

  From a background job:

      def perform(user_id) do
        case MyApp.RateLimiter.check(user_id) do
          :ok -> send_digest(user_id)
          {:error, reason} -> {:error, reason}
        end
      end
  """

  use GenServer

  @window_ms 60_000
  @sweep_interval_ms :timer.seconds(10)

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the limits file.
    * `:name` - name of the process and of its ETS table. Defaults to
      `#{inspect(__MODULE__)}`. Pass a different name to run a second limiter.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Counts one request by `user_id` and reports whether it is allowed.

  Returns `:ok` when the user has made fewer requests than their limit in the
  last minute. Returns `{:error, :rate_limited}` when they have reached it, and
  `{:error, :unknown_user}` when the limits file has no entry for them.
  """
  @spec check(GenServer.name(), term()) :: :ok | {:error, :rate_limited | :unknown_user}
  def check(name \\ __MODULE__, user_id) do
    case fetch_limit(name, user_id) do
      {:ok, limit} -> take_slot(name, user_id, limit)
      :error -> {:error, :unknown_user}
    end
  end

  @impl true
  def init({name, config_path}) do
    table_options = [:named_table, :public, :bag, read_concurrency: true, write_concurrency: true]
    :ets.new(name, table_options)
    :persistent_term.put(limits_key(name), load_limits!(config_path))
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, name}
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{:_, {:"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, name}
  end

  defp fetch_limit(name, user_id) do
    limits = :persistent_term.get(limits_key(name))
    Map.fetch(limits, user_id)
  end

  # Insert first, then count, then remove the row again if over the limit. An
  # allowed request's row is never removed, so the last allowed request to count
  # sees every earlier allowed row. Two checks can therefore both be rejected
  # near the limit, but never both allowed past it.
  defp take_slot(name, user_id, limit) do
    now = System.monotonic_time(:millisecond)
    object = {user_id, {now, System.unique_integer([:monotonic])}}
    :ets.insert(name, object)

    if count_in_window(name, user_id, now) <= limit do
      :ok
    else
      :ets.delete_object(name, object)
      {:error, :rate_limited}
    end
  end

  defp count_in_window(name, user_id, now) do
    cutoff = now - @window_ms
    rows = :ets.lookup(name, user_id)
    Enum.count(rows, fn {_user_id, {sent_at, _ref}} -> sent_at > cutoff end)
  end

  defp load_limits!(config_path) do
    {limits, _binding} = Code.eval_file(config_path)
    Map.new(limits, &limit_entry/1)
  end

  defp limit_entry({user_id, limit}) when is_integer(limit) and limit >= 0 do
    {user_id, limit}
  end

  defp limits_key(name), do: {__MODULE__, name}
end
