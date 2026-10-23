ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry __MODULE__.Registry

  def registry, do: @registry

  # deliver/2 runs inside the server, so its registered name is the test's key
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(@registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.registry()})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.registry(), name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "start_link/1" do
    test "fails without a mailer", %{module: module, test: test} do
      name = Module.concat([module, test, "NoMailer"])
      child_spec = Supervisor.child_spec({Subscriptions, name: name}, id: :no_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} =
               start_supervised(child_spec)
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps the topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      pid = self()

      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", pid, "ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok
      # the call returns after the publish cast has been handled
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :update) == :ok
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}
    end

    test "notifies a subscriber once per subscription", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:notification, "news", :update}
      refute_receive {:notification, _topic, _payload}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      survivor = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(survivor, :kill) end)

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", survivor) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      # a synchronous call to the server, so its own :DOWN message was handled
      _state = :sys.get_state(server)

      %{subscriber: subscriber, survivor: survivor}
    end

    test "removes it from every topic", %{server: server, subscriber: subscriber} do
      refute subscriber in Subscriptions.subscribers(server, "news")
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers", %{server: server, survivor: survivor} do
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", survivor]
    end

    test "still notifies the other subscribers", %{server: server, survivor: survivor} do
      Process.exit(survivor, :kill)
      ref = Process.monitor(survivor)
      assert_receive {:DOWN, ^ref, :process, ^survivor, _reason}

      assert Subscriptions.publish(server, "news", :update) == :ok
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits normally" do
    test "removes it from the topic", %{server: server} do
      subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
      _state = :sys.get_state(server)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end
end
