ExUnit.start()

defmodule Notify.SubscriptionsTest do
  # Not async: the mailer reaches the test through a registered name, and the server
  # under test runs under its fixed default name.
  use ExUnit.Case

  alias Notify.Subscriptions

  defmodule TestMailer do
    @moduledoc false
    @behaviour Notify.Mailer

    # deliver/2 runs inside the server and takes no test context, so each test registers
    # itself under this module's name to receive the mail.
    @impl true
    def deliver(to, subject) do
      send(__MODULE__, {:mail, to, subject})
      if to == "bounce@example.com", do: {:error, :bounced}, else: :ok
    end
  end

  setup do
    Process.register(self(), TestMailer)

    # Tests call this pid, not the registered name. The test supervisor restarts a crashed
    # server with no subscribers, which through the name would look like a clean removal.
    %{server: start_supervised!({Subscriptions, mailer: TestMailer})}
  end

  describe "start_link/1" do
    test "registers the server as Notify.Subscriptions by default", %{server: server} do
      assert Process.whereis(Subscriptions) == server
    end

    test "registers the server under :name, with its own subscribers", %{server: server} do
      other =
        start_supervised!({Subscriptions, mailer: TestMailer, name: :other_server}, id: :other)

      assert Process.whereis(:other_server) == other

      assert Subscriptions.subscribe(:other_server, "news", self()) == :ok
      assert Subscriptions.subscribers(:other_server, "news") == [self()]
      assert Subscriptions.subscribers(server, "news") == []
    end

    @tag :capture_log
    test "fails to start without a :mailer" do
      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} =
               start_supervised({Subscriptions, name: :no_mailer}, id: :no_mailer)
    end
  end

  describe "the default server" do
    test "is used when no server is given" do
      assert Subscriptions.subscribe("news", self()) == :ok
      assert Subscriptions.subscribers("news") == [self()]

      assert Subscriptions.publish("news", "hello") == :ok
      assert_receive {:notification, "news", "hello"}
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "leaves other topics unchanged", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "sports") == ["a@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first, pids and addresses alike", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", self(), "a@example.com"]
    end

    test "lists a subscriber under every topic it subscribed to", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "sports", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == [self()]
    end
  end

  describe "publish/3 to processes" do
    test "sends the topic and payload", %{server: server} do
      payload = %{id: 1, tags: ["elixir"]}
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", payload) == :ok

      assert_receive {:notification, "news", ^payload}
    end

    test "reaches every process on the topic", %{server: server} do
      first = start_subscriber()
      second = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", first)
      :ok = Subscriptions.subscribe(server, "news", second)

      Subscriptions.publish(server, "news", "hello")

      assert_receive {^first, {:notification, "news", "hello"}}
      assert_receive {^second, {:notification, "news", "hello"}}
    end

    test "returns before subscribers are notified", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :sys.suspend(server)

      assert Subscriptions.publish(server, "news", "hello") == :ok
      refute_received {:notification, "news", "hello"}

      :sys.resume(server)
      assert_receive {:notification, "news", "hello"}
    end

    test "skips processes subscribed to other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())

      Subscriptions.publish(server, "news", "hello")
      await_publish(server)

      refute_received {:notification, _topic, _payload}
    end

    test "does nothing on a topic with no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", "hello") == :ok
      await_publish(server)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3 to email addresses" do
    test "mails each address with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:mail, "a@example.com", "New on news"}
      assert_receive {:mail, "b@example.com", "New on news"}
    end

    test "reaches addresses and processes on the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:mail, "a@example.com", "New on news"}
      assert_receive {:notification, "news", "hello"}
    end

    test "skips addresses subscribed to other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")

      Subscriptions.publish(server, "news", "hello")
      await_publish(server)

      refute_received {:mail, _to, _subject}
    end

    test "continues with the remaining subscribers after a failed delivery", %{server: server} do
      # The most recent subscriber is notified first, so the failure comes before the others.
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "bounce@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:mail, "bounce@example.com", "New on news"}
      assert_receive {:notification, "news", "hello"}
      assert Subscriptions.subscribers(server, "news") == ["bounce@example.com", self()]
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed after finishing normally", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)

      assert_subscribers(server, "news", [])
    end

    test "it is removed after being killed, and the server keeps running", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", subscriber)

      Process.exit(subscriber, :kill)

      assert_subscribers(server, "news", [])
      assert Process.alive?(server)
    end

    test "it is removed from every topic", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "sports", subscriber)

      send(subscriber, :stop)

      assert_subscribers(server, "news", [])
      assert_subscribers(server, "sports", [])
    end

    test "it is removed completely if it subscribed to a topic twice", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)

      assert_subscribers(server, "news", [])
    end

    test "it is removed if it was already dead when subscribed", %{server: server} do
      subscriber = start_subscriber()
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      assert_subscribers(server, "news", [])
    end

    test "the other subscribers stay and keep being notified", %{server: server} do
      leaving = start_subscriber()
      staying = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", leaving)
      :ok = Subscriptions.subscribe(server, "news", staying)

      send(leaving, :stop)
      assert_subscribers(server, "news", [staying, "a@example.com"])

      Subscriptions.publish(server, "news", "hello")

      assert_receive {^staying, {:notification, "news", "hello"}}
      assert_receive {:mail, "a@example.com", "New on news"}
    end
  end

  # A process that stays alive until told to stop and forwards everything else it receives
  # to the test, tagged with its own pid.
  defp start_subscriber do
    test = self()
    start_supervised!({Task, fn -> forward_to(test) end}, id: make_ref())
  end

  defp forward_to(test) do
    receive do
      :stop ->
        :ok

      message ->
        send(test, {self(), message})
        forward_to(test)
    end
  end

  # publish/3 is a cast and messages between two processes stay in order, so once this
  # returns the server has handled the publish and its messages are in the test's mailbox.
  defp await_publish(server), do: :sys.get_state(server)

  # The server learns of an exit from its own :DOWN message. Nothing tells the test when that
  # has been handled, and a :DOWN sent to the test could arrive first, so this retries.
  defp assert_subscribers(server, topic, expected, attempts \\ 100) do
    actual = Subscriptions.subscribers(server, topic)

    if actual != expected and attempts > 0 do
      Process.sleep(10)
      assert_subscribers(server, topic, expected, attempts - 1)
    else
      assert actual == expected
    end
  end
end
