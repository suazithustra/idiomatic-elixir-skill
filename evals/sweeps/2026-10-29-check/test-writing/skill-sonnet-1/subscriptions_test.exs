ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: name})

    %{server: server}
  end

  describe "subscribe/3" do
    test "returns :ok for a pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
    end

    test "returns :ok for an email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
    end

    test "adds the subscriber to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "keeps topics separate", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ann@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      expected = ["bob@example.com", self(), "ann@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "sends a notification to every subscribed pid", %{server: server} do
      test_pid = self()

      other =
        spawn_link(fn ->
          receive do
            message -> send(test_pid, {:other_received, message})
          end
        end)

      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", other) == :ok

      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert_receive {:notification, "news", :hello}
      assert_receive {:other_received, {:notification, "news", :hello}}
    end

    test "mails an email subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :hello) == :ok

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert Subscriptions.subscribers(server, "news") == []
      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      # A synchronous call returns after the server's own :DOWN message is handled.
      :sys.get_state(server)

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps publishing to the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "keeps the server running", %{server: server} do
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits normally" do
    test "removes it from the topic", %{server: server} do
      subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
      :sys.get_state(server)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end
end
