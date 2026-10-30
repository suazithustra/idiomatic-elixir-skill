ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @registry Notify.SubscriptionsTest.Mailers

  # Runs inside the server, so the server's registered name finds the test process.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(@registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  @registry Notify.SubscriptionsTest.Mailers

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Mailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns the subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "first@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "second@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "sport") == []
    end
  end

  describe "publish/3 to a pid" do
    test "sends {:notification, topic, payload} to the subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "sends one notification per publish", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}

      settle(server)
      refute_receive {:notification, _topic, _payload}
    end

    test "does not notify a pid subscribed to another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      settle(server)
      refute_receive {:notification, _topic, _payload}
    end
  end

  describe "publish/3 to an email address" do
    test "mails the address with a subject that names the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:notification, "news", :updated}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from every topic it subscribed to", %{server: server} do
      subscriber = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sport", subscriber) == :ok

      exit_normally(subscriber)
      settle(server)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      subscriber = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      exit_normally(subscriber)
      settle(server)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "removes a subscriber killed from outside and keeps notifying the rest", %{
      server: server
    } do
      subscriber = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      kill(subscriber)
      settle(server)

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp exit_normally(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  # publish/3 is a cast, and the server handles a subscriber's :DOWN separately from the
  # test process; a synchronous call returns only after the server has handled what came before it.
  defp settle(server), do: :sys.get_state(server)
end
