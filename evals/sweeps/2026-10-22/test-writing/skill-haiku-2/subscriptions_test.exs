ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule Mailer do
    @moduledoc false
    @behaviour Notify.Mailer

    @registry Notify.SubscriptionsTest.Registry

    # deliver/2 runs inside the server, so the server's registered name is the key
    # that leads back to the test process
    @impl true
    def deliver(to, subject) do
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(@registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

  @registry Notify.SubscriptionsTest.Registry

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    start_supervised!({Subscriptions, mailer: Mailer, name: name})
    %{server: name}
  end

  describe "subscribe/3" do
    test "adds a process to the subscribers of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "first@example.com")
      :ok = Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["second@example.com", "first@example.com"]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "publish/3 to process subscribers" do
    test "sends a notification to a subscribed process", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      first = spawn_forwarder(self())
      second = spawn_forwarder(self())
      :ok = Subscriptions.subscribe(server, "news", first)
      :ok = Subscriptions.subscribe(server, "news", second)

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:forwarded, ^first, {:notification, "news", :updated}}
      assert_receive {:forwarded, ^second, {:notification, "news", :updated}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())

      :ok = Subscriptions.publish(server, "news", :updated)

      # The publish cast is handled before get_state returns, so a notification
      # would already be in the mailbox by the time of refute_received.
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
    end

    test "publishing to a topic with no subscribers does nothing", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :updated)

      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails each email subscriber of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "does not mail subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      :sys.get_state(server)
      refute_received {:delivered, _to, _subject}
    end

    test "notifies process subscribers and mails email subscribers in one publish",
         %{server: server} do
      forwarder = spawn_forwarder(self())
      :ok = Subscriptions.subscribe(server, "news", forwarder)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:forwarded, ^forwarder, {:notification, "news", :updated}}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid = spawn_waiter()
      :ok = Subscriptions.subscribe(server, "news", pid)
      %{pid: pid}
    end

    test "removes the process when it exits normally", %{server: server, pid: pid} do
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process when it is killed", %{server: server, pid: pid} do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process from every topic it subscribed to", %{server: server, pid: pid} do
      :ok = Subscriptions.subscribe(server, "sports", pid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, pid: pid} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end
  end

  defp spawn_waiter do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp spawn_forwarder(test_pid) do
    spawn(fn ->
      receive do
        message -> send(test_pid, {:forwarded, self(), message})
      end
    end)
  end
end
