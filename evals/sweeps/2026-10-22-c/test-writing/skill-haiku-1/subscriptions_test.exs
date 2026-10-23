ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  @registry Notify.SubscriptionsTest.Registry

  defmodule TestMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      # Runs inside the subscriptions server, so its registered name identifies the test.
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "returns :ok", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
    end

    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "news@example.com") == :ok
      assert Subscriptions.subscribe(server, "sport", "sport@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["news@example.com"]
      assert Subscriptions.subscribers(server, "sport") == ["sport@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "first@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "second@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end
  end

  describe "publish/3" do
    test "sends the notification to a process subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "notifies a process and an email subscriber of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      # publish/3 is a cast; the synchronous call returns once it has been handled.
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid = spawn_waiting()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      %{pid: pid}
    end

    test "removes the process from its topic", %{server: server, pid: pid} do
      exit_subscriber(server, pid, :normal)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process from every topic it subscribed to", %{server: server, pid: pid} do
      assert Subscriptions.subscribe(server, "sport", pid) == :ok
      exit_subscriber(server, pid, :normal)
      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "removes the process after it crashes", %{server: server, pid: pid} do
      exit_subscriber(server, pid, :boom)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, pid: pid} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      exit_subscriber(server, pid, :normal)

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com", self()]
    end

    test "still notifies the remaining subscribers after the exit", %{server: server, pid: pid} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      exit_subscriber(server, pid, :normal)
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
    end
  end

  defp spawn_waiting do
    spawn(fn ->
      receive do
        {:exit, reason} -> exit(reason)
      end
    end)
  end

  defp exit_subscriber(server, pid, reason) do
    ref = Process.monitor(pid)
    send(pid, {:exit, reason})
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
    # The server receives its own :DOWN message asynchronously; a synchronous call
    # after it has handled that message.
    :sys.get_state(server)
  end
end
