ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the server, so the server's registered name finds the test process.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, nil}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  @registry Notify.SubscriptionsTest.Registry

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup context do
    server = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(@registry, server, nil)
    start_supervised!({Subscriptions, mailer: Mailer, name: server})
    %{server: server}
  end

  describe "subscribe/3" do
    test "returns :ok when a pid subscribes", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sport", "bob@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sport") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self(), "ann@example.com"]
    end

    test "drops a pid that was already dead when it subscribed", %{server: server} do
      subscriber = spawn_subscriber()
      stop_subscriber(subscriber)

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  describe "publish/3 to a pid" do
    test "sends {:notification, topic, payload} to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok
      assert_receive {:notification, "news", "hello"}
    end

    test "does not send a pid the topics it did not subscribe to", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", self()) == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      # publish/3 is a cast. Reading the state waits until the server has handled it.
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
    end

    test "keeps running when the topic has no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", "hello") == :ok

      :sys.get_state(server)
      assert Process.whereis(server)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3 to an email address" do
    test "delivers to the address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "delivers once to each email address on the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
      :sys.get_state(server)
      refute_received {:delivered, _to, _subject}
    end

    test "does not deliver to an address subscribed to another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", "ann@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      :sys.get_state(server)
      refute_received {:delivered, _to, _subject}
    end

    test "notifies a pid and an email address on the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sport", subscriber) == :ok
      %{subscriber: subscriber}
    end

    test "removes the pid from every topic it subscribed to", %{
      server: server,
      subscriber: subscriber
    } do
      stop_subscriber(subscriber)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other subscribers of its topics", %{
      server: server,
      subscriber: subscriber
    } do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      stop_subscriber(subscriber)

      eventually(fn -> Subscriptions.subscribers(server, "news") == ["ann@example.com"] end)
    end

    test "removes the pid when it is killed", %{server: server, subscriber: subscriber} do
      kill_subscriber(subscriber)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_subscriber(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp kill_subscriber(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  # The server handles its own :DOWN message, and nothing tells the test when it has
  # done so. Poll the server's answer until the removal shows, up to about one second.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("the condition did not hold after polling the server")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
