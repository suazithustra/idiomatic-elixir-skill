ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Reports each delivery to the process registered under this module's name.
  @impl true
  def deliver(to, subject) do
    send(__MODULE__, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.TestSubscriber do
  @moduledoc false

  # Forwards every message it receives to the test process. It exits when it
  # receives :stop, or when the test process exits.
  def start(test_pid) do
    spawn(fn ->
      ref = Process.monitor(test_pid)
      loop(test_pid, ref)
    end)
  end

  defp loop(test_pid, ref) do
    receive do
      :stop ->
        :ok

      {:DOWN, ^ref, :process, _, _} ->
        :ok

      message ->
        send(test_pid, {:seen, self(), message})
        loop(test_pid, ref)
    end
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.{Subscriptions, TestSubscriber}

  setup do
    server = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: server})
    %{server: server}
  end

  describe "subscribe/3" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "orders", self())
    end

    test "lists the most recent subscriber first", %{server: server} do
      first = TestSubscriber.start(self())
      second = TestSubscriber.start(self())
      Subscriptions.subscribe(server, "orders", first)
      Subscriptions.subscribe(server, "orders", second)

      assert Subscriptions.subscribers(server, "orders") == [second, first]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "orders", self())

      assert Subscriptions.subscribers(server, "billing") == []
    end
  end

  describe "publish/3 to pid subscribers" do
    test "sends the notification to the subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "orders", self())

      Subscriptions.publish(server, "orders", %{id: 1})

      assert_receive {:notification, "orders", %{id: 1}}
    end

    test "sends each publish to every subscriber of the topic", %{server: server} do
      first = TestSubscriber.start(self())
      second = TestSubscriber.start(self())
      Subscriptions.subscribe(server, "orders", first)
      Subscriptions.subscribe(server, "orders", second)

      Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:seen, ^first, {:notification, "orders", :shipped}}
      assert_receive {:seen, ^second, {:notification, "orders", :shipped}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "billing", self())

      Subscriptions.publish(server, "orders", :shipped)
      # A call is handled after the publish, so any notification would already be in the mailbox.
      Subscriptions.subscribers(server, "billing")

      refute_received {:notification, _, _}
    end

    test "does nothing for a topic without subscribers and keeps serving calls", %{server: server} do
      Subscriptions.publish(server, "nobody", :hello)

      assert Subscriptions.subscribers(server, "nobody") == []
    end
  end

  describe "when a subscribed pid exits" do
    test "removes it from the topic when it stops normally", %{server: server} do
      pid = TestSubscriber.start(self())
      Subscriptions.subscribe(server, "orders", pid)
      ref = Process.monitor(pid)

      send(pid, :stop)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "removes it from every topic it subscribed to when it is killed", %{server: server} do
      pid = TestSubscriber.start(self())
      Subscriptions.subscribe(server, "orders", pid)
      Subscriptions.subscribe(server, "billing", pid)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert Subscriptions.subscribers(server, "orders") == []
      assert Subscriptions.subscribers(server, "billing") == []
    end

    test "keeps the other subscribers of the topic and still notifies them", %{server: server} do
      leaving = TestSubscriber.start(self())
      staying = TestSubscriber.start(self())
      Subscriptions.subscribe(server, "orders", leaving)
      Subscriptions.subscribe(server, "orders", staying)
      ref = Process.monitor(leaving)

      send(leaving, :stop)
      assert_receive {:DOWN, ^ref, :process, ^leaving, :normal}

      assert Subscriptions.subscribers(server, "orders") == [staying]

      Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:seen, ^staying, {:notification, "orders", :shipped}}
    end
  end
end

defmodule Notify.SubscriptionsEmailTest do
  # Notify.TestMailer reports to the process registered under its name, and only one
  # test process can hold that name at a time, so these tests run serially.
  use ExUnit.Case, async: false

  alias Notify.{Subscriptions, TestSubscriber}

  setup do
    Process.register(self(), Notify.TestMailer)
    server = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: server})
    %{server: server}
  end

  describe "publish/3 to email subscribers" do
    test "mails the address with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "orders", "ops@example.com")

      Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:delivered, "ops@example.com", "New on orders"}
    end

    test "mails email subscribers and notifies pid subscribers", %{server: server} do
      pid = TestSubscriber.start(self())
      Subscriptions.subscribe(server, "orders", pid)
      Subscriptions.subscribe(server, "orders", "ops@example.com")

      Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:delivered, "ops@example.com", "New on orders"}
      assert_receive {:seen, ^pid, {:notification, "orders", :shipped}}
    end

    test "does not mail subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "billing", "ops@example.com")

      Subscriptions.publish(server, "orders", :shipped)
      # A call is handled after the publish, so any delivery would already be in the mailbox.
      Subscriptions.subscribers(server, "billing")

      refute_received {:delivered, _, _}
    end
  end

  describe "when a subscribed pid exits" do
    test "keeps the email subscribers of the topic", %{server: server} do
      pid = TestSubscriber.start(self())
      ref = Process.monitor(pid)
      Subscriptions.subscribe(server, "orders", pid)
      Subscriptions.subscribe(server, "orders", "ops@example.com")

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert Subscriptions.subscribers(server, "orders") == ["ops@example.com"]

      Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:delivered, "ops@example.com", "New on orders"}
    end
  end
end
