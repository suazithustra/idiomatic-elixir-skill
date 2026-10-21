ExUnit.start()

defmodule Notify.TestMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(:subscriptions_test, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    # The mailer runs inside the server process, so it reaches the test process by name.
    Process.register(self(), :subscriptions_test)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})

    %{server: name}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "sport", "ann@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sport") == ["ann@example.com"]
    end

    test "uses the default server name when none is given" do
      # The setup block already runs a child with the default child ID, so give this one another.
      child = Supervisor.child_spec({Subscriptions, mailer: Notify.TestMailer}, id: :default_name)
      start_supervised!(child)

      assert :ok = Subscriptions.subscribe("news", self())
      assert Subscriptions.subscribers("news") == [self()]
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", "hello")
      assert_receive {:notification, "news", "hello"}
    end

    test "sends an email to an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", "hello")
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sport", self())

      Subscriptions.publish(server, "news", "hello")
      sync(server, "news")

      refute_received {:notification, _, _}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      Subscriptions.publish(server, "empty", "hello")
      sync(server, "empty")

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "keeps subscribers after publishing", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", "hello")
      sync(server, "news")

      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end
  end

  describe "when a subscribed process exits" do
    test "removes the process from its topic", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes the process after a normal exit", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes the process from every topic it subscribed to", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sport", pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert_eventually(fn -> Subscriptions.subscribers(server, "sport") == [] end)
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)
    end

    test "keeps email subscribers", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "ann@example.com")

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == ["ann@example.com"] end)
    end

    test "removes a subscriber that was already dead when it subscribed", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      Subscriptions.subscribe(server, "news", pid)

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  # publish/3 is a cast, so the server may not have handled it yet. A call from the
  # same process is handled after the cast, so this returns once the publish is done.
  defp sync(server, topic) do
    Subscriptions.subscribers(server, topic)
  end

  defp spawn_waiting_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # The server removes exited processes when it handles their :DOWN message. That message
  # races with the test's own monitor message, so poll instead of asserting once.
  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
