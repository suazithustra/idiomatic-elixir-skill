ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the test's key
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "start_link/1" do
    test "fails to start without a mailer", context do
      name = Module.concat(context.module, "#{context.test} without mailer")

      # The `setup` server already runs under the default child id.
      spec = Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _spec}} =
               start_supervised(spec)
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ana@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "keeps subscriptions to other topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "sports", "ana@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ana@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ana@example.com")

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      relay = relay_to_test()
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", relay)
      Subscriptions.subscribe(server, "news", "ana@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:relayed, {:notification, "news", :update}}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "ana@example.com")

      Subscriptions.publish(server, "news", :update)
      sync(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :update)
      sync(server)

      refute_received _message
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ana@example.com")

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server, subscriber: subscriber} do
      refute subscriber in await_subscribers(server, "news", &(subscriber not in &1))
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers", %{server: server, subscriber: subscriber} do
      assert await_subscribers(server, "news", &(subscriber not in &1)) ==
               ["ana@example.com", self()]
    end

    test "still notifies the remaining subscribers", %{server: server, subscriber: subscriber} do
      await_subscribers(server, "news", &(subscriber not in &1))

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end
  end

  # A process that stays alive until killed.
  defp spawn_subscriber do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  # A process that forwards what it receives to the test process.
  defp relay_to_test do
    test_pid = self()

    spawn_link(fn ->
      receive do
        message -> send(test_pid, {:relayed, message})
      end
    end)
  end

  # The server handles messages in order, so the reply means earlier casts were handled.
  defp sync(server), do: :sys.get_state(server)

  # The server learns of an exit through its own monitor, which can arrive after the
  # test's `:DOWN`, so ask again until the subscriber list satisfies `done?`.
  defp await_subscribers(server, topic, done?, attempts \\ 50) do
    subscribers = Subscriptions.subscribers(server, topic)

    if done?.(subscribers) or attempts == 0 do
      subscribers
    else
      :erlang.yield()
      await_subscribers(server, topic, done?, attempts - 1)
    end
  end
end
