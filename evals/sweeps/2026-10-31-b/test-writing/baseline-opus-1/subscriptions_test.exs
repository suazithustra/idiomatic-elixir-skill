ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  # Reports each delivery to the test that owns the server. `deliver/2` runs in the
  # server process, so `self()` finds that test in this registry, which is also the
  # module's name. Addresses starting with "rejected" fail the way a real mailer can.
  @impl true
  def deliver(to, subject) do
    [{test, _value}] = Registry.lookup(__MODULE__, self())
    send(test, {:delivered, to, subject})

    if String.starts_with?(to, "rejected"), do: {:error, :rejected}, else: :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer})
    :ok
  end

  setup %{test: test} do
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: test})
    {:ok, _owner} = Registry.register(TestMailer, server, nil)
    %{server: server}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "orders", self()) == :ok

      assert Subscriptions.subscribers(server, "orders") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "orders", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "orders") == ["ann@example.com"]
    end

    test "lets one subscriber join several topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "invoices", self())

      assert Subscriptions.subscribers(server, "orders") == [self()]
      assert Subscriptions.subscribers(server, "invoices") == [self()]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "returns pids and email addresses, most recent first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "bob@example.com")

      assert Subscriptions.subscribers(server, "orders") ==
               ["bob@example.com", self(), "ann@example.com"]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "invoices", "bob@example.com")

      assert Subscriptions.subscribers(server, "orders") == ["ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to a subscribed process", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      assert Subscriptions.publish(server, "orders", %{id: 1}) == :ok

      assert_receive {:notification, "orders", %{id: 1}}
    end

    test "mails a subscribed address with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")

      assert Subscriptions.publish(server, "orders", %{id: 1}) == :ok

      assert_receive {:delivered, "ann@example.com", "New on orders"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      other = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", other)
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "orders", "bob@example.com")

      :ok = Subscriptions.publish(server, "orders", :payload)

      assert_receive {:notification, "orders", :payload}
      assert_receive {^other, {:notification, "orders", :payload}}
      assert_receive {:delivered, "ann@example.com", "New on orders"}
      assert_receive {:delivered, "bob@example.com", "New on orders"}
    end

    test "notifies nobody when the topic has no subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "invoices", self())
      :ok = Subscriptions.subscribe(server, "invoices", "ann@example.com")

      assert Subscriptions.publish(server, "orders", :payload) == :ok

      await_publish(server)
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "carries on after a mailer error", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "orders", self())
      # Subscribed last, so it is notified first and the others follow the failure.
      :ok = Subscriptions.subscribe(server, "orders", "rejected@example.com")

      :ok = Subscriptions.publish(server, "orders", :payload)

      assert_receive {:delivered, "rejected@example.com", "New on orders"}
      assert_receive {:notification, "orders", :payload}
      assert_receive {:delivered, "ann@example.com", "New on orders"}

      assert Subscriptions.subscribers(server, "orders") ==
               ["rejected@example.com", self(), "ann@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    for reason <- [:normal, :shutdown, :crashed] do
      test "removes it after it exits with #{inspect(reason)}", %{server: server} do
        subscriber = spawn_subscriber()
        :ok = Subscriptions.subscribe(server, "orders", subscriber)
        assert Subscriptions.subscribers(server, "orders") == [subscriber]

        exit_subscriber(subscriber, unquote(reason))

        await_subscribers(server, "orders", [])
      end
    end

    test "removes it from every topic", %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "invoices", subscriber)

      exit_subscriber(subscriber, :normal)

      await_subscribers(server, "orders", [])
      await_subscribers(server, "invoices", [])
    end

    test "removes it entirely when it subscribed to a topic twice", %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "orders", subscriber)

      exit_subscriber(subscriber, :normal)

      await_subscribers(server, "orders", [])
    end

    test "removes a process that was already dead when it subscribed", %{server: server} do
      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead, :normal}

      :ok = Subscriptions.subscribe(server, "orders", dead)

      await_subscribers(server, "orders", [])
    end

    test "keeps the other subscribers in order", %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "orders", self())

      exit_subscriber(subscriber, :normal)

      await_subscribers(server, "orders", [self(), "ann@example.com"])
    end

    test "still notifies the other subscribers", %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "orders", subscriber)
      :ok = Subscriptions.subscribe(server, "orders", self())

      exit_subscriber(subscriber, :normal)
      await_subscribers(server, "orders", [self(), "ann@example.com"])

      :ok = Subscriptions.publish(server, "orders", :payload)

      assert_receive {:notification, "orders", :payload}
      assert_receive {:delivered, "ann@example.com", "New on orders"}
    end
  end

  describe "the default server" do
    test "is used when no server is given" do
      # Only this test takes the default name, and tests in a module never overlap.
      start_supervised!({Subscriptions, mailer: TestMailer}, id: :default_server)

      assert Subscriptions.subscribe("orders", self()) == :ok
      assert Subscriptions.subscribers("orders") == [self()]
      assert Subscriptions.publish("orders", :payload) == :ok

      assert_receive {:notification, "orders", :payload}
    end
  end

  # A subscriber other than the test process, which can exit without ending the test.
  defp spawn_subscriber do
    test = self()
    spawn(fn -> forward_notifications(test) end)
  end

  defp forward_notifications(test) do
    receive do
      {:exit, reason} ->
        exit(reason)

      notification ->
        send(test, {self(), notification})
        forward_notifications(test)
    end
  end

  defp exit_subscriber(subscriber, reason), do: send(subscriber, {:exit, reason})

  # `publish/3` is a cast. The server handles one caller's messages in order, so once
  # this call returns the publish is done and whatever it sent the test has arrived.
  defp await_publish(server), do: Subscriptions.subscribers(server, "any topic")

  # The exit reaches the server through its own monitor, and no message tells the test
  # when that has happened, so this polls until the list matches or the retries run out.
  defp await_subscribers(server, topic, expected, retries \\ 100) do
    case Subscriptions.subscribers(server, topic) do
      ^expected ->
        :ok

      _not_yet when retries > 0 ->
        Process.sleep(10)
        await_subscribers(server, topic, expected, retries - 1)

      actual ->
        assert actual == expected
    end
  end
end
