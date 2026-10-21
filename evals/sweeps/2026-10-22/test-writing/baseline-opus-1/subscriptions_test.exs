ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  # Deliveries run inside the Subscriptions server, not the test process, so each
  # one is forwarded as {:email, to, subject} to whichever test process registered
  # the address `to` in Notify.TestMailer.Registry.
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    for {pid, _value} <- Registry.lookup(Notify.TestMailer.Registry, to) do
      send(pid, {:email, to, subject})
    end

    :ok
  end
end

defmodule Notify.FailingMailer do
  @moduledoc false
  # Forwards the delivery like Notify.TestMailer, then reports a failure.
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    :ok = Notify.TestMailer.deliver(to, subject)
    {:error, :smtp_unavailable}
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.TestMailer.Registry})
    :ok
  end

  setup do
    # name: nil leaves the server unregistered, so tests can run concurrently.
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: nil})
    %{server: server}
  end

  describe "start_link/1" do
    @tag :capture_log
    test "requires a :mailer" do
      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} =
               start_supervised({Subscriptions, name: nil}, id: :without_mailer)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "a topic nobody subscribed to has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "lists pids and email addresses, most recent first", %{server: server} do
      other = spawn_subscriber()

      assert :ok = Subscriptions.subscribe(server, "orders", self())
      assert :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")
      assert :ok = Subscriptions.subscribe(server, "orders", other)

      assert Subscriptions.subscribers(server, "orders") == [other, "ada@example.com", self()]
    end

    test "keeps each topic's subscribers separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "invoices", "ada@example.com")

      assert Subscriptions.subscribers(server, "orders") == [self()]
      assert Subscriptions.subscribers(server, "invoices") == ["ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends {:notification, topic, payload} to a subscribed process", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      assert :ok = Subscriptions.publish(server, "orders", %{id: 1})

      assert_receive {:notification, "orders", %{id: 1}}
    end

    test "mails each subscribed address with the topic in the subject", %{server: server} do
      ada = register_address()
      grace = register_address()
      :ok = Subscriptions.subscribe(server, "orders", ada)
      :ok = Subscriptions.subscribe(server, "orders", grace)

      :ok = Subscriptions.publish(server, "orders", %{id: 1})

      assert_receive {:email, ^ada, "New on orders"}
      assert_receive {:email, ^grace, "New on orders"}
    end

    test "notifies only the subscribers of the published topic", %{server: server} do
      address = register_address()
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "invoices", address)

      :ok = Subscriptions.publish(server, "orders", :created)
      # The server handles this call after the publish, so any email it was going
      # to send has already arrived when the call returns.
      _ = Subscriptions.subscribers(server, "orders")

      assert_received {:notification, "orders", :created}
      refute_received {:email, ^address, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "orders", :created)
      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "keeps notifying the other subscribers when a delivery fails" do
      server =
        start_supervised!({Subscriptions, mailer: Notify.FailingMailer, name: nil},
          id: :failing_mailer
        )

      address = register_address()
      :ok = Subscriptions.subscribe(server, "orders", self())
      # Subscribed last, so it is notified first.
      :ok = Subscriptions.subscribe(server, "orders", address)

      :ok = Subscriptions.publish(server, "orders", :created)

      assert_receive {:email, ^address, "New on orders"}
      assert_receive {:notification, "orders", :created}
      assert Subscriptions.subscribers(server, "orders") == [address, self()]
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed and the other subscribers are kept", %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")

      send(subscriber, :stop)

      assert_subscribers_eventually(server, "orders", ["ada@example.com", self()])
    end

    test "a crashed process is removed from every topic it subscribed to", %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "invoices", subscriber)

      Process.exit(subscriber, :kill)

      assert_subscribers_eventually(server, "orders", [])
      assert_subscribers_eventually(server, "invoices", [])
    end

    test "a process subscribed twice to a topic is removed entirely", %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "orders", subscriber)

      send(subscriber, :stop)

      assert_subscribers_eventually(server, "orders", [])
    end

    test "a process that is already dead when it subscribes is removed", %{server: server} do
      subscriber = spawn(fn -> :ok end)
      ref = Process.monitor(subscriber)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}

      :ok = Subscriptions.subscribe(server, "orders", subscriber)

      assert_subscribers_eventually(server, "orders", [])
    end
  end

  # Gives the test process a fresh address whose emails Notify.TestMailer forwards to it.
  defp register_address do
    address = "user#{System.unique_integer([:positive])}@example.com"
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, address, nil)
    address
  end

  # A subscriber process that stays alive until it is sent :stop.
  defp spawn_subscriber do
    spawn_link(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # The server learns about an exit from a :DOWN message, which can reach it after
  # a call we make next, so poll until it has caught up.
  defp assert_subscribers_eventually(server, topic, expected, attempts \\ 50) do
    case Subscriptions.subscribers(server, topic) do
      ^expected ->
        :ok

      actual when attempts == 0 ->
        assert actual == expected

      _actual ->
        Process.sleep(10)
        assert_subscribers_eventually(server, topic, expected, attempts - 1)
    end
  end
end

defmodule Notify.SubscriptionsDefaultNameTest do
  # Registers the server under its default global name, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  test "registers as Notify.Subscriptions so the server argument can be left out" do
    start_supervised!({Subscriptions, mailer: Notify.TestMailer})

    :ok = Subscriptions.subscribe("orders", self())
    :ok = Subscriptions.publish("orders", :created)

    assert_receive {:notification, "orders", :created}
    assert Subscriptions.subscribers("orders") == [self()]
  end
end
