defmodule Notify.Mailer do
  @moduledoc """
  Sends an email. Implementations are passed to `Notify.Subscriptions` as the `:mailer` option.
  """

  @callback deliver(to :: String.t(), subject :: String.t()) :: :ok | {:error, term()}
end

defmodule Notify.Subscriptions do
  @moduledoc """
  Keeps the subscribers of each topic and notifies them when something is published.

  A subscriber is a pid, which receives `{:notification, topic, payload}`, or an email
  address, which is mailed through the `:mailer` module given to `start_link/1`.
  Subscribed processes are removed when they exit.
  """

  use GenServer

  @type topic :: String.t()
  @type subscriber :: pid() | String.t()

  @doc """
  Starts the server.

  ## Options

    * `:mailer` - a module implementing `Notify.Mailer`. Required.
    * `:name` - the registered name. Defaults to `Notify.Subscriptions`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribes a pid or an email address to `topic`."
  @spec subscribe(GenServer.server(), topic(), subscriber()) :: :ok
  def subscribe(server \\ __MODULE__, topic, subscriber) do
    GenServer.call(server, {:subscribe, topic, subscriber})
  end

  @doc "Publishes `payload` on `topic`. Subscribers are notified after this call returns."
  @spec publish(GenServer.server(), topic(), term()) :: :ok
  def publish(server \\ __MODULE__, topic, payload) do
    GenServer.cast(server, {:publish, topic, payload})
  end

  @doc "Returns the subscribers of `topic`, most recent first."
  @spec subscribers(GenServer.server(), topic()) :: [subscriber()]
  def subscribers(server \\ __MODULE__, topic) do
    GenServer.call(server, {:subscribers, topic})
  end

  @impl true
  def init(opts) do
    {:ok, %{mailer: Keyword.fetch!(opts, :mailer), topics: %{}}}
  end

  @impl true
  def handle_call({:subscribe, topic, subscriber}, _from, state) do
    if is_pid(subscriber), do: Process.monitor(subscriber)
    topics = Map.update(state.topics, topic, [subscriber], &[subscriber | &1])
    {:reply, :ok, %{state | topics: topics}}
  end

  def handle_call({:subscribers, topic}, _from, state) do
    {:reply, Map.get(state.topics, topic, []), state}
  end

  @impl true
  def handle_cast({:publish, topic, payload}, state) do
    for subscriber <- Map.get(state.topics, topic, []) do
      notify(subscriber, topic, payload, state.mailer)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    topics = Map.new(state.topics, fn {topic, subs} -> {topic, List.delete(subs, pid)} end)
    {:noreply, %{state | topics: topics}}
  end

  defp notify(pid, topic, payload, _mailer) when is_pid(pid) do
    send(pid, {:notification, topic, payload})
  end

  defp notify(email, topic, _payload, mailer) when is_binary(email) do
    mailer.deliver(email, "New on #{topic}")
  end
end
