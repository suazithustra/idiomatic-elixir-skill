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
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: name})

    %{server: server}
  end

  describe "subscribe/3" do
    test "adds a process to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "grace@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["grace@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "grace@example.com") == :ok

      expected = ["grace@example.com", self(), "ada@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "grace@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      # the cast is handled before :sys.get_state/1 replies
      _state = :sys.get_state(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :updated) == :ok
      _state = :sys.get_state(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert Process.alive?(server)
    end
  end
end
