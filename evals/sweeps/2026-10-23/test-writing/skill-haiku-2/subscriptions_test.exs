ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the Subscriptions server, so the server's registered name
  # is the key under which the test process registered itself.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Mailers, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  @registry Notify.SubscriptionsTest.Mailers

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of its topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of its topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["bob@example.com", "ann@example.com"]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification tuple to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", {:order, 42}) == :ok

      assert_receive {:notification, "news", {:order, 42}}
    end

    test "delivers an email to a subscribed address through the mailer", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", {:order, 42}) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies a pid and an email address on the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", {:order, 42}) == :ok

      assert_receive {:notification, "news", {:order, 42}}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "bob@example.com") == :ok

      assert Subscriptions.publish(server, "news", {:order, 42}) == :ok

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "keeps the server running when the topic has no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "empty", {:order, 42}) == :ok

      assert Subscriptions.subscribers(server, "empty") == []
      refute_receive {:notification, _topic, _payload}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the subscribers of its topic", %{server: server} do
      pid = spawn_waiting_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      pid = spawn_waiting_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sports", pid) == :ok

      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_waiting_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "removes every entry for a pid subscribed to the same topic twice", %{server: server} do
      pid = spawn_waiting_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  defp spawn_waiting_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
