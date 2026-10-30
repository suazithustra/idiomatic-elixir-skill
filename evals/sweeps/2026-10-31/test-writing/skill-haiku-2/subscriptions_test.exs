ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so the server's registered name is the
  # test's key in the registry. The test process registers itself under it.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.TestMailer.Registry, server)
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
    assert {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds the process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end
  end

  describe "publish/3 to a process subscriber" do
    test "sends the topic and payload to the process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
    end

    test "does not send a topic's notification to subscribers of another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "sport", :final_score) == :ok
      # The call is handled after the cast, so any notification has already been sent.
      assert Subscriptions.subscribers(server, "sport") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "publish/3 to an email subscriber" do
    test "mails the address with the topic as the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "notifies a process and mails an address on the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com", self()]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sport", "fan@example.com") == :ok
      assert Subscriptions.subscribers(server, "sport") == ["fan@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    test "removes the process when it exits normally", %{server: server} do
      subscriber = start_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)

      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process when it is killed", %{server: server} do
      subscriber = start_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)

      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process from every topic it subscribed to", %{server: server} do
      subscriber = start_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sport", subscriber) == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)

      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}
      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other subscribers of the topic and still mails them", %{server: server} do
      subscriber = start_subscriber()
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)

      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com", self()]

      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end
  end

  # A Task that waits for :stop, so the test controls when the process exits.
  # start_supervised! stops it at the end of the test if it is still alive.
  defp start_subscriber do
    start_supervised!({Task, fn -> wait_for_stop() end})
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end
end
