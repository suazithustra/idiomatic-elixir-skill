ExUnit.start()

defmodule Notify.SubscriptionsTest.FakeMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(Application.fetch_env!(:notify, :mail_listener), {:mail, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.FakeMailer

  setup do
    Application.put_env(:notify, :mail_listener, self())
    on_exit(fn -> Application.delete_env(:notify, :mail_listener) end)

    server = start_supervised!({Subscriptions, mailer: FakeMailer, name: unique_name()})
    %{server: server}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of a topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of a topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps topics independent", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "sport", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sport") == ["grace@example.com"]
    end

    test "uses the default name when none is given" do
      start_supervised!(Supervisor.child_spec({Subscriptions, mailer: FakeMailer}, id: :default))

      Subscriptions.subscribe("news", self())

      assert Subscriptions.subscribers("news") == [self()]
    end
  end

  describe "subscribers/2" do
    test "lists the most recent subscriber first", %{server: server} do
      first = spawn_relay(self())
      second = spawn_relay(self())

      Subscriptions.subscribe(server, "news", first)
      Subscriptions.subscribe(server, "news", second)

      assert Subscriptions.subscribers(server, "news") == [second, first]
    end

    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", "hello")
      sync(server)

      assert_received {:notification, "news", "hello"}
    end

    test "mails an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", "hello")
      sync(server)

      assert_received {:mail, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      relay = spawn_relay(self())
      Subscriptions.subscribe(server, "news", relay)
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", "hello")
      sync(server)

      assert_receive {:relayed, ^relay, {:notification, "news", "hello"}}
      assert_received {:mail, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sport", self())
      Subscriptions.subscribe(server, "sport", "grace@example.com")

      Subscriptions.publish(server, "news", "hello")
      sync(server)

      refute_received {:notification, _, _}
      refute_received {:mail, _, _}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", "hello")
      sync(server)

      refute_received {:notification, _, _}
      refute_received {:mail, _, _}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits" do
    test "removes the process when it exits normally", %{server: server} do
      subscriber = spawn_relay(self())
      Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)
      wait_for_exit(subscriber)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes the process when it is killed", %{server: server} do
      subscriber = spawn_relay(self())
      Subscriptions.subscribe(server, "news", subscriber)

      Process.exit(subscriber, :kill)
      wait_for_exit(subscriber)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes the process from every topic it subscribed to", %{server: server} do
      subscriber = spawn_relay(self())
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sport", subscriber)

      Process.exit(subscriber, :kill)
      wait_for_exit(subscriber)

      eventually(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sport") == []
      end)
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      leaving = spawn_relay(self())
      staying = spawn_relay(self())
      Subscriptions.subscribe(server, "news", leaving)
      Subscriptions.subscribe(server, "news", staying)
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Process.exit(leaving, :kill)
      wait_for_exit(leaving)

      eventually(fn ->
        Subscriptions.subscribers(server, "news") == ["ada@example.com", staying]
      end)
    end

    test "still notifies the remaining subscribers", %{server: server} do
      leaving = spawn_relay(self())
      staying = spawn_relay(self())
      Subscriptions.subscribe(server, "news", leaving)
      Subscriptions.subscribe(server, "news", staying)
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Process.exit(leaving, :kill)
      wait_for_exit(leaving)
      eventually(fn -> Subscriptions.subscribers(server, "news") == ["ada@example.com", staying] end)

      Subscriptions.publish(server, "news", "hello")
      sync(server)

      assert_receive {:relayed, ^staying, {:notification, "news", "hello"}}
      assert_received {:mail, "ada@example.com", "New on news"}
      assert Process.alive?(server)
    end
  end

  defp unique_name do
    :"subscriptions_#{System.unique_integer([:positive])}"
  end

  # Casts are asynchronous. Returning from `:sys.get_state/1` means the server has
  # handled every message sent to it before this call.
  defp sync(server) do
    :sys.get_state(server)
  end

  # Forwards every message it receives to `parent`, so the test can see what a
  # pid subscriber was sent. Stops on `:stop`.
  defp spawn_relay(parent) do
    pid = spawn(fn -> relay(parent) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp relay(parent) do
    receive do
      :stop ->
        :ok

      message ->
        send(parent, {:relayed, self(), message})
        relay(parent)
    end
  end

  defp wait_for_exit(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # The server handles `:DOWN` messages asynchronously with respect to the test,
  # so poll until the removal has happened.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      true ->
        flunk("condition was not met in time")
    end
  end
end
