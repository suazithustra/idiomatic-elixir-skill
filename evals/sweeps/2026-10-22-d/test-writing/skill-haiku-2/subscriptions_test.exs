ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule Mailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, nil}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.SubscriptionsTest.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    assert {:ok, _owner} = Registry.register(Notify.SubscriptionsTest.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Mailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to pid subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:notification, "news", :launched}
    end

    test "mails email subscribers with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      Subscriptions.publish(server, "news", :launched)
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the topic alike", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      Subscriptions.publish(server, "news", :launched)
      assert_receive {:notification, "news", :launched}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "returns :ok when the topic has no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :launched) == :ok
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", self()) == :ok
      Subscriptions.publish(server, "news", :launched)
      # publish/3 is a cast; a synchronous call waits until the server has handled it.
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end

    test "lists only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "sport", "grace@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = start_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      %{subscriber: subscriber}
    end

    test "removes it from every topic it subscribed to", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "sport", subscriber) == :ok
      stop_subscriber(subscriber)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "removes it when it is killed", %{server: server, subscriber: subscriber} do
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      stop_subscriber(subscriber)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end

    test "keeps notifying the remaining subscribers", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      stop_subscriber(subscriber)

      Subscriptions.publish(server, "news", :launched)
      assert_receive {:notification, "news", :launched}
      assert Process.alive?(server)
    end
  end

  defp start_subscriber do
    start_supervised!({Task, &wait_for_stop/0})
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end

  defp stop_subscriber(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
