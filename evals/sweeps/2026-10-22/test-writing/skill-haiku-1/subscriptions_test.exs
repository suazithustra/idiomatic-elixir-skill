ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so the server's registered name identifies the test
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.SubscriptionsTest.Registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(Notify.SubscriptionsTest.Registry, name, nil)

    server =
      start_supervised!({Subscriptions, mailer: Notify.SubscriptionsTest.Mailer, name: name})

    %{server: server, name: name}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "orders", self())
      assert Subscriptions.subscribers(server, "orders") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      assert Subscriptions.subscribers(server, "orders") == ["ops@example.com"]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.subscribe(server, "invoices", self())

      assert Subscriptions.subscribers(server, "orders") == ["ops@example.com"]
      assert Subscriptions.subscribers(server, "invoices") == [self()]
    end
  end

  describe "subscribers/2" do
    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "first@example.com")
      :ok = Subscriptions.subscribe(server, "orders", "second@example.com")

      assert Subscriptions.subscribers(server, "orders") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  describe "publish/3" do
    test "sends a pid subscriber the topic and payload", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:notification, "orders", %{id: 42}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")

      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:delivered, "ops@example.com", "New on orders"}
    end

    test "sends one mail to each email subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.subscribe(server, "orders", "billing@example.com")

      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:delivered, "ops@example.com", "New on orders"}
      assert_receive {:delivered, "billing@example.com", "New on orders"}
    end

    test "notifies every subscriber of the topic, pid and email alike", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")

      :ok = Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:notification, "orders", :shipped}
      assert_receive {:delivered, "ops@example.com", "New on orders"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "invoices", self())

      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      sync(server)
      refute_receive {:notification, _topic, _payload}
    end

    test "sends nothing when the topic has no subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "orders", %{id: 42})

      sync(server)
      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end
  end

  describe "start_link/1" do
    test "registers the server under the :name option", %{server: server, name: name} do
      assert Process.whereis(name) == server
    end

    test "fails to start without a :mailer option" do
      {result, _log} =
        ExUnit.CaptureLog.with_log(fn -> GenServer.start(Subscriptions, []) end)

      assert {:error, {%KeyError{key: :mailer}, _stacktrace}} = result
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      victim = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", victim)
      :ok = Subscriptions.subscribe(server, "invoices", victim)

      %{victim: victim}
    end

    test "removes it from every topic it subscribed to", %{server: server, victim: victim} do
      Process.exit(victim, :kill)
      wait_for_exit(victim)

      assert Subscriptions.subscribers(server, "orders") == []
      assert Subscriptions.subscribers(server, "invoices") == []
    end

    test "removes it when it exits normally", %{server: server, victim: victim} do
      send(victim, :stop)
      wait_for_exit(victim)

      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "keeps the other subscribers in their order", %{server: server, victim: victim} do
      :ok = Subscriptions.subscribe(server, "orders", "ops@example.com")
      :ok = Subscriptions.subscribe(server, "orders", self())

      Process.exit(victim, :kill)
      wait_for_exit(victim)

      assert Subscriptions.subscribers(server, "orders") == [self(), "ops@example.com"]
    end

    test "keeps notifying the remaining subscribers", %{server: server, victim: victim} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      Process.exit(victim, :kill)
      wait_for_exit(victim)
      :ok = Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:notification, "orders", :shipped}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process has already exited" do
    test "does not keep it as a subscriber", %{server: server} do
      dead = spawn(fn -> :ok end)
      wait_for_exit(dead)

      :ok = Subscriptions.subscribe(server, "orders", dead)

      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp wait_for_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # publish/3 is a cast. The server handles messages in order, so a call that returns
  # after the publish means the publish has been handled.
  defp sync(server), do: :sys.get_state(server)
end
