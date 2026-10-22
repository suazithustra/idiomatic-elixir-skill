ExUnit.start()

defmodule Notify.SubscriptionsTest.FakeMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # The mailer only receives `to` and `subject`, so deliveries are reported to
  # whichever process registered itself under this module's name.
  @impl true
  def deliver(to, subject) do
    send(__MODULE__, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.FakeMailer

  setup do
    server = start_supervised!({Subscriptions, mailer: FakeMailer, name: nil})
    %{server: server}
  end

  defp spawn_subscriber do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  # Publishing is a cast; a call afterwards guarantees the server has handled it.
  defp sync(server), do: Subscriptions.subscribers(server, "sync")

  describe "subscribe/3 and subscribers/2" do
    test "a topic with no subscribers has an empty list", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns pid and email subscribers, most recent first", %{server: server} do
      pid = spawn_subscriber()

      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", pid]
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3 to process subscribers" do
    test "sends the notification to every subscribed process", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())

      :ok = Subscriptions.publish(server, "news", :hello)
      sync(server)

      refute_received {:notification, _, _}
    end

    test "publishing to a topic without subscribers is a no-op", %{server: server} do
      assert Subscriptions.publish(server, "empty", :hello) == :ok
      assert sync(server) == []
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sports", pid)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "other subscribed processes are kept", %{server: server} do
      leaving = spawn_subscriber()
      staying = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", leaving)
      :ok = Subscriptions.subscribe(server, "news", staying)

      ref = Process.monitor(leaving)
      Process.exit(leaving, :kill)
      assert_receive {:DOWN, ^ref, :process, ^leaving, :killed}

      assert Subscriptions.subscribers(server, "news") == [staying]
    end

    test "a process that is already dead is removed right away", %{server: server} do
      pid = spawn_subscriber()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      :ok = Subscriptions.subscribe(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "the server keeps running", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", :still_here)

      assert_receive {:notification, "news", :still_here}
      assert Process.alive?(server)
    end
  end
end

defmodule Notify.SubscriptionsEmailTest do
  # Not async: FakeMailer reports to a globally registered name.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.FakeMailer

  setup do
    Process.register(self(), FakeMailer)
    server = start_supervised!({Subscriptions, mailer: FakeMailer, name: nil})
    %{server: server}
  end

  test "mails every subscribed address with the topic in the subject", %{server: server} do
    :ok = Subscriptions.subscribe(server, "news", "a@example.com")
    :ok = Subscriptions.subscribe(server, "news", "b@example.com")

    :ok = Subscriptions.publish(server, "news", %{id: 1})

    assert_receive {:delivered, "a@example.com", "New on news"}
    assert_receive {:delivered, "b@example.com", "New on news"}
  end

  test "notifies process and email subscribers of the same topic", %{server: server} do
    :ok = Subscriptions.subscribe(server, "news", self())
    :ok = Subscriptions.subscribe(server, "news", "a@example.com")

    :ok = Subscriptions.publish(server, "news", :hello)

    assert_receive {:notification, "news", :hello}
    assert_receive {:delivered, "a@example.com", "New on news"}
  end

  test "does not mail subscribers of other topics", %{server: server} do
    :ok = Subscriptions.subscribe(server, "sports", "a@example.com")

    :ok = Subscriptions.publish(server, "news", :hello)
    Subscriptions.subscribers(server, "sync")

    refute_received {:delivered, _, _}
  end

  test "the default name is Notify.Subscriptions" do
    start_supervised!({Subscriptions, mailer: FakeMailer}, id: :named)

    :ok = Subscriptions.subscribe("news", "a@example.com")
    :ok = Subscriptions.publish("news", :hello)

    assert_receive {:delivered, "a@example.com", "New on news"}
    assert Subscriptions.subscribers("news") == ["a@example.com"]
  end

  test "requires a mailer" do
    assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} =
             start_supervised({Subscriptions, name: nil}, id: :no_mailer)
  end
end
