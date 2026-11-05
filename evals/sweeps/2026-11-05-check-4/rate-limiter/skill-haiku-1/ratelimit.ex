defmodule MyApp.RateLimiter do
  @moduledoc """
  Limits how many requests each user may make in a rolling one-minute window.

  Each user's limit comes from a JSON file that is read when the limiter starts:

      {
        "default_limit": 60,
        "limits": {"42": 10, "7": 300}
      }

  Users not listed under `"limits"` get `"default_limit"`. A limit is the number of
  requests allowed in any 60-second span.

  ## Starting

  Add the limiter to the supervision tree, with the config path taken from the
  application environment:

      children = [
        {MyApp.RateLimiter, config_path: Application.fetch_env!(:my_app, :rate_limit_config)},
        MyAppWeb.Endpoint
      ]

  If the file cannot be read or is malformed, the limiter fails to start and the
  supervisor reports the reason.

  ## Callers

  A Phoenix controller checks the limit before doing its work:

      def create(conn, params) do
        case MyApp.RateLimiter.check(conn.assigns.current_user.id) do
          :ok ->
            do_create(conn, params)

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> json(%{error: "rate_limited"})
        end
      end

  A background job does the same and returns an error when the limit is reached:

      def perform(user_id, export) do
        with :ok <- MyApp.RateLimiter.check(user_id), do: build_export(export)
      end
  """

  use GenServer

  @window_ms :timer.minutes(1)

  @table_options [
    :named_table,
    :ordered_set,
    :public,
    read_concurrency: true,
    write_concurrency: true
  ]

  @typedoc "A user's ID: an integer, or the string form used in the config file."
  @type user_id :: integer() | String.t()

  @doc """
  Starts the limiter.

  ## Options

    * `:config_path` - required. Path to the JSON limits file.
    * `:name` - the registered name, which is also the name of the ETS table that
      holds the request counts. Defaults to `#{inspect(__MODULE__)}`. Tests start
      their own instance under a different name.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config_path = Keyword.fetch!(opts, :config_path)
    GenServer.start_link(__MODULE__, {name, config_path}, name: name)
  end

  @doc """
  Records one request for `user_id` and reports whether it is within the limit.

  Returns `:ok` when the request is allowed, and `{:error, :rate_limited}` when the
  user has already used their limit in the last minute. A denied request is not
  counted, so the user can make a request again as soon as older ones leave the window.

  The check runs in the caller's process and reads ETS directly. It does not wait
  on the limiter process.
  """
  @spec check(atom(), user_id()) :: :ok | {:error, :rate_limited}
  def check(name \\ __MODULE__, user_id) do
    user = user_key(user_id)
    limit = limit_for(name, user)
    now = System.monotonic_time(:millisecond)
    key = {user, now, make_ref()}
    :ets.insert(name, {key})
    count = count_since(name, user, now - @window_ms)

    if count <= limit do
      :ok
    else
      :ets.delete(name, key)
      {:error, :rate_limited}
    end
  end

  @impl true
  def init({name, config_path}) do
    case read_config(config_path) do
      {:ok, config} ->
        create_table(name, config)
        schedule_sweep()
        {:ok, name}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sweep, name) do
    cutoff = System.monotonic_time(:millisecond) - @window_ms
    :ets.select_delete(name, [{{{:_, :"$1", :_}}, [{:"=<", :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, name}
  end

  # Each request is one row, {{user, timestamp, ref}}. The ref makes rows unique
  # when two requests share a millisecond. Limits are rows of their own, keyed by
  # {:limit, user}, and the fallback is the row keyed by :default_limit.
  defp create_table(name, config) do
    :ets.new(name, @table_options)
    :ets.insert(name, {:default_limit, config.default})
    :ets.insert(name, Enum.map(config.limits, fn {user, limit} -> {{:limit, user}, limit} end))
  end

  defp limit_for(name, user) do
    case :ets.lookup(name, {:limit, user}) do
      [{{:limit, ^user}, limit}] ->
        limit

      [] ->
        default_limit(name)
    end
  end

  defp default_limit(name) do
    [{:default_limit, limit}] = :ets.lookup(name, :default_limit)
    limit
  end

  defp count_since(name, user, cutoff) do
    :ets.select_count(name, [{{{user, :"$1", :_}}, [{:>, :"$1", cutoff}], [true]}])
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  defp user_key(user_id) when is_integer(user_id), do: Integer.to_string(user_id)
  defp user_key(user_id) when is_binary(user_id), do: user_id

  defp read_config(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode(contents) do
      parse_config(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  defp decode(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_config(%{"default_limit" => default, "limits" => limits})
       when is_integer(default) and default >= 0 and is_map(limits) do
    case Enum.find(limits, &invalid_limit?/1) do
      nil -> {:ok, %{default: default, limits: limits}}
      {user, _limit} -> {:error, {:invalid_limit, user}}
    end
  end

  defp parse_config(_decoded), do: {:error, :invalid_config}

  defp invalid_limit?({_user, limit}), do: not is_integer(limit) or limit < 0
end
