ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule FakeMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      send(:subscriptions_test_listener, {:delivered, to, subject})
      :ok
    end
  end

  setup do
    Process.register(self(), :subscriptions_test_listener)
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: FakeMailer, name: name})

    %{server: name}
  end

  describe "start_link/1" do
    test "registers under the default name when no :name is given" do
      child = Supervisor.child_spec({Subscriptions, mailer: FakeMailer}, id: :default_name)
      start_supervised!(child)

      assert Subscriptions.subscribers("news") == []
    end

    @tag :capture_log
    test "fails when :mailer is missing" do
      Process.flag(:trap_exit, true)

      assert {:error, _reason} = Subscriptions.start_link(name: :subscriptions_no_mailer)
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      first = spawn_listener(self())
      second = spawn_listener(self())

      Subscriptions.subscribe(server, "news", first)
      Subscriptions.subscribe(server, "news", second)

      assert Subscriptions.subscribers(server, "news") == [second, first]
    end
  end

  describe "publish/3 to pid subscribers" do
    test "sends a notification message to the subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
    end

    test "sends the notification to every subscribed pid", %{server: server} do
      first = spawn_listener(self())
      second = spawn_listener(self())
      Subscriptions.subscribe(server, "news", first)
      Subscriptions.subscribe(server, "news", second)

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:heard, ^first, {:notification, "news", "hello"}}
      assert_receive {:heard, ^second, {:notification, "news", "hello"}}
    end

    test "does not notify pids subscribed to other topics", %{server: server} do
      Subscriptions.subscribe(server, "sport", self())

      Subscriptions.publish(server, "news", "hello")
      flush(server)

      refute_received {:notification, _, _}
    end

    test "publishing to a topic with no subscribers does nothing", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", "hello")
      flush(server)

      assert Process.alive?(Process.whereis(server))
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3 to email subscribers" do
    test "delivers through the mailer with a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "delivers to every email subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "grace@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "does not mail subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sport", "ada@example.com")

      Subscriptions.publish(server, "news", "hello")
      flush(server)

      refute_received {:delivered, _, _}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for an unknown topic", %{server: server} do
      assert Subscriptions.subscribers(server, "unknown") == []
    end

    test "returns pids and email addresses together", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end
  end

  describe "when a subscribed process exits" do
    test "is removed from the topic after a normal exit", %{server: server} do
      listener = spawn_listener(self())
      Subscriptions.subscribe(server, "news", listener)

      send(listener, :stop)

      await_subscribers(server, "news", [])
    end

    test "is removed from the topic after being killed", %{server: server} do
      listener = spawn_listener(self())
      Subscriptions.subscribe(server, "news", listener)

      Process.exit(listener, :kill)

      await_subscribers(server, "news", [])
    end

    test "is removed from every topic it subscribed to", %{server: server} do
      listener = spawn_listener(self())
      Subscriptions.subscribe(server, "news", listener)
      Subscriptions.subscribe(server, "sport", listener)

      send(listener, :stop)

      await_subscribers(server, "news", [])
      await_subscribers(server, "sport", [])
    end

    test "leaves the other subscribers in place and in order", %{server: server} do
      kept = spawn_listener(self())
      gone = spawn_listener(self())
      Subscriptions.subscribe(server, "news", kept)
      Subscriptions.subscribe(server, "news", gone)
      Subscriptions.subscribe(server, "news", "ada@example.com")

      send(gone, :stop)

      await_subscribers(server, "news", ["ada@example.com", kept])

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:heard, ^kept, {:notification, "news", "hello"}}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "is not notified of later publishes", %{server: server} do
      listener = spawn_listener(self())
      Subscriptions.subscribe(server, "news", listener)
      send(listener, :stop)
      await_subscribers(server, "news", [])

      Subscriptions.publish(server, "news", "hello")
      flush(server)

      refute_received {:heard, ^listener, _}
    end

    test "a pid that is already dead when subscribed is removed right away", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      Subscriptions.subscribe(server, "news", pid)

      await_subscribers(server, "news", [])
    end
  end

  # A process that forwards every message it gets to `target` until told to stop.
  defp spawn_listener(target) do
    spawn(fn -> listen(target) end)
  end

  defp listen(target) do
    receive do
      :stop ->
        :ok

      message ->
        send(target, {:heard, self(), message})
        listen(target)
    end
  end

  # A call from the test process is handled after its earlier casts, so this
  # returns only once a preceding publish has been processed.
  defp flush(server) do
    Subscriptions.subscribers(server, "flush")
  end

  # Removal happens when the server handles the monitor's :DOWN message, which
  # arrives asynchronously. Poll until the list matches or give up.
  defp await_subscribers(server, topic, expected, attempts \\ 100) do
    case Subscriptions.subscribers(server, topic) do
      ^expected ->
        :ok

      _actual when attempts > 0 ->
        Process.sleep(5)
        await_subscribers(server, topic, expected, attempts - 1)

      actual ->
        flunk("expected subscribers #{inspect(expected)}, got #{inspect(actual)}")
    end
  end
end
