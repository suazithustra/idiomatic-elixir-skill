ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    # deliver/2 runs inside the server, so its registered name is the test's key
    @impl true
    def deliver(to, subject) do
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(TestMailer.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

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
    test "adds a process to the topic's subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      assert Subscriptions.subscribers(server, "orders") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")

      assert Subscriptions.subscribers(server, "orders") == ["ops@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "first@example.com")
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "last@example.com")

      assert Subscriptions.subscribers(server, "orders") ==
               ["last@example.com", self(), "first@example.com"]
    end

    test "lists only the subscribers of the given topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.subscribe(server, "invoices", "billing@example.com")

      assert Subscriptions.subscribers(server, "orders") == ["ops@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to subscribed processes", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:notification, "orders", %{id: 42}}
    end

    test "mails subscribed addresses with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:delivered, "ops@example.com", "New on orders"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.subscribe(server, "orders", "sales@example.com")
      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:notification, "orders", %{id: 42}}
      assert_receive {:delivered, "ops@example.com", "New on orders"}
      assert_receive {:delivered, "sales@example.com", "New on orders"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.publish(server, "invoices", %{id: 7})
      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      # The server handles casts in order, so anything sent for "invoices"
      # would be in the mailbox before the "orders" messages.
      assert_receive {:notification, "orders", %{id: 42}}
      assert_receive {:delivered, "ops@example.com", "New on orders"}
      refute_received {:notification, "invoices", _payload}
      refute_received {:delivered, "ops@example.com", "New on invoices"}
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes the process from every topic it subscribed to", %{
      server: server,
      subscriber: subscriber
    } do
      refute subscriber in Subscriptions.subscribers(server, "orders")
      refute subscriber in Subscriptions.subscribers(server, "invoices")
    end

    test "keeps the topic's other subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == ["ops@example.com"]
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:delivered, "ops@example.com", "New on orders"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Task, fn -> Process.sleep(:infinity) end})
    :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
    :ok = Subscriptions.subscribe(server, "orders", subscriber)
    :ok = Subscriptions.subscribe(server, "invoices", subscriber)
    :ok = stop_supervised!(Task)
    %{subscriber: subscriber}
  end
end
