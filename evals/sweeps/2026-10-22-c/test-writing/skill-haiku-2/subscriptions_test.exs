ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the Subscriptions server, so the server's registered name
  # is the key that finds the test process that owns this delivery.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.SubscriptionsTest.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.SubscriptionsTest.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Mailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      assert :ok = Subscriptions.subscribe(server, "sports", "fan@example.com")
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["fan@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns the subscribers most recent first", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "first@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.publish(server, "news", {:updated, 42})
      assert_receive {:notification, "news", {:updated, 42}}
    end

    test "sends an email to a subscribed address", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      assert :ok = Subscriptions.publish(server, "news", {:updated, 42})
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "notifies both pid and email subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      assert :ok = Subscriptions.publish(server, "news", {:updated, 42})
      assert_receive {:notification, "news", {:updated, 42}}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "sports", self())
      assert :ok = Subscriptions.publish(server, "news", :news_payload)
      assert :ok = Subscriptions.publish(server, "sports", :sports_payload)
      assert_receive {:notification, "sports", :sports_payload}
      # The server handles publishes in order, so the sports notification
      # arriving means the news publish was already handled.
      refute_received {:notification, "news", _payload}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the subscribers of its topic", %{server: server} do
      subscriber = start_subscriber()
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", subscriber)

      stop_process(subscriber)

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      subscriber = start_subscriber()
      assert :ok = Subscriptions.subscribe(server, "news", subscriber)
      assert :ok = Subscriptions.subscribe(server, "sports", subscriber)

      stop_process(subscriber)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      subscriber = start_subscriber()
      assert :ok = Subscriptions.subscribe(server, "news", subscriber)
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      stop_process(subscriber)
      assert :ok = Subscriptions.publish(server, "news", {:updated, 42})

      assert_receive {:notification, "news", {:updated, 42}}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end
  end

  defp start_subscriber do
    start_supervised!({Agent, fn -> nil end})
  end

  defp stop_process(pid) do
    ref = Process.monitor(pid)
    Agent.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
