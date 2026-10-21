defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits each user to N requests in any rolling 60-second window.

  N comes from a configuration file read once when the limiter starts.
  The file holds Erlang terms, one per line, each ending in a period:

      %% priv/rate_limits.terms
      {default, 60}.
      {"user-42", 300}.
      {"user-77", 10}.

  `default` applies to every user not listed. The file must contain exactly
  one `default` entry. Text IDs are written as strings and match binary IDs
  passed to `check/1`. Integer IDs are written as integers.

  ## Starting it

  Add it to the supervision tree, before the processes that call it:

      children = [
        MyApp.Repo,
        {MyApp.RateLimiter,
         config_path: Application.app_dir(:my_app, "priv/rate_limits.terms")},
        MyAppWeb.Endpoint
      ]

  ## Callers

  A Phoenix controller that returns 429 when the user is over the limit:

      defmodule MyAppWeb.ExportController do
        use MyAppWeb, :controller

        alias MyApp.RateLimiter

        def create(conn, _params) do
          user = conn.assigns.current_user

          case RateLimiter.check(user.id) do
            :ok ->
              json(conn, %{status: "queued"})

            {:error, :rate_limited} ->
              conn
              |> put_status(:too_many_requests)
              |> json(%{error: "rate_limited"})
          end
        end
      end

  A background job that stops and reports back when the user is over the limit:

      defmodule MyApp.Jobs.SendDigest do
        alias MyApp.RateLimiter

        def perform(user_id) do
          case RateLimiter.check(user_id) do
            :ok -> send_digest(user_id)
            {:error, :rate_limited} = error -> error
          end
        end
      end

  ## How it counts

  Each accepted request is stored as a row with its timestamp. A request is
  checked by first inserting its own row, then counting the rows for that user
  in the last minute. If the count is over the limit, the request deletes its
  own row and is rejected. Rows of accepted requests are never removed early,
  so the count never admits more than N requests in a window. Two requests
  arriving at the same moment can both be rejected, which is the safe error.

  The tables are written by callers directly, with ETS operations that each
  act on one row. The owning process only creates the tables, loads the limits,
  and removes expired rows once a minute.
  """

  use GenServer

  @window :timer.minutes(1)
  @sweep_interval :timer.minutes(1)

  @requests_table :"#{__MODULE__}.Requests"
  @limits_table :"#{__MODULE__}.Limits"

  @doc """
  Starts the limiter and loads the limits from `:config_path`.

  Returns `{:error, reason}` when the file cannot be read or contains an
  invalid entry, so a bad file stops the application at boot.
  """
  def start_link(opts) do
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, config_path, name: __MODULE__)
  end

  @doc """
  Records one request for `user_id` and reports whether it is within the limit.

  Runs in the caller's process and does not go through the GenServer. Raises
  `ArgumentError` if the limiter is not running.

  ## Examples

      :ok = MyApp.RateLimiter.check("user-42")
  """
  @spec check(term()) :: :ok | {:error, :rate_limited}
  def check(user_id) do
    limit = limit_for(user_id)
    now = now_ms()
    key = {user_id, System.unique_integer([:monotonic, :positive])}

    true = :ets.insert(@requests_table, {key, now})

    if count_recent(user_id, now) <= limit do
      :ok
    else
      :ets.delete(@requests_table, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init(config_path) do
    with {:ok, limits} <- read_limits(config_path) do
      :ets.new(@requests_table, [:named_table, :public, :ordered_set, write_concurrency: true])
      :ets.new(@limits_table, [:named_table, :protected, :set, read_concurrency: true])
      true = :ets.insert(@limits_table, limits)

      schedule_sweep()
      {:ok, nil}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now_ms() - @window
    :ets.select_delete(@requests_table, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    schedule_sweep()
    {:noreply, state}
  end

  defp limit_for(user_id) do
    case :ets.lookup(@limits_table, {:user, user_id}) do
      [{_key, limit}] -> limit
      [] -> default_limit()
    end
  end

  defp default_limit do
    [{:default, limit}] = :ets.lookup(@limits_table, :default)
    limit
  end

  defp count_recent(user_id, now) do
    cutoff = now - @window
    :ets.select_count(@requests_table, [{{{user_id, :_}, :"$1"}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp read_limits(config_path) do
    with {:ok, terms} <- :file.consult(config_path) do
      parse_limits(terms)
    end
  end

  defp parse_limits(terms) do
    {defaults, user_terms} = Enum.split_with(terms, &match?({:default, _}, &1))

    with [{:default, default}] <- defaults,
         :ok <- validate_limit(default),
         {:ok, users} <- parse_user_limits(user_terms) do
      {:ok, [{:default, default} | users]}
    else
      [] -> {:error, :missing_default}
      [_, _ | _] -> {:error, :duplicate_default}
      {:error, _reason} = error -> error
    end
  end

  defp parse_user_limits(terms) do
    Enum.reduce_while(terms, {:ok, []}, fn
      {user_id, limit}, {:ok, acc} ->
        case validate_limit(limit) do
          :ok -> {:cont, {:ok, [{{:user, normalize_user_id(user_id)}, limit} | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_entry, other}}}
    end)
  end

  # The terms file reads "text" as a charlist, which would never match the
  # binary that callers pass, so convert it here.
  defp normalize_user_id(user_id) when is_list(user_id), do: List.to_string(user_id)
  defp normalize_user_id(user_id), do: user_id

  defp validate_limit(limit) when is_integer(limit) and limit >= 0, do: :ok
  defp validate_limit(limit), do: {:error, {:invalid_limit, limit}}
end
