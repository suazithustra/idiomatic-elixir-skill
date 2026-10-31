ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so the server's registered name is the test's key
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
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["bob@example.com", "ada@example.com"]
    end
  end

  describe "publish/3 to pid subscribers" do
    test "sends the payload to a subscribed pid as a notification", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify a pid subscribed to another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      # subscribers/2 is a call, so the publish cast above is handled before it returns
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails the subscriber with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "mails email subscribers and notifies pid subscribers of the same topic",
         %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not mail a subscriber of another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", "bob@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    test "removes the pid from the subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a pid that was killed", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the pid from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sports", pid) == :ok

      stop_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      stop_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "keeps the server running and serving calls", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_subscriber(pid)

      assert Process.alive?(server)
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  # A process that waits for :stop, so the test controls when it exits.
  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_subscriber(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
