ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so its registered name identifies the test.
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
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

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    start_supervised!({Subscriptions, mailer: Mailer, name: name})
    %{server: name}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "sports", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", :hello)
      assert_receive {:notification, "news", :hello}
    end

    test "mails the topic to a subscribed email address", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :hello)
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies a pid and mails an address subscribed to the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :hello)
      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())

      Subscriptions.publish(server, "news", :hello)
      # publish/3 is a cast; :sys.get_state/1 returns once the server has handled it.
      _ = :sys.get_state(server)
      refute_received {:notification, _, _}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the subscribers of the topic, most recent first", %{server: server} do
      subscriber = spawn_subscriber()

      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", subscriber)

      assert Subscriptions.subscribers(server, "news") == [subscriber, "ada@example.com", self()]
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from every topic and keeps the other subscribers", %{server: server} do
      subscriber = spawn_subscriber()
      ref = Process.monitor(subscriber)

      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)

      send(subscriber, :stop)

      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
      # The server gets its own :DOWN message separately, so sync with it before checking.
      _ = :sys.get_state(server)
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes it when it crashes", %{server: server} do
      subscriber = spawn_subscriber()
      ref = Process.monitor(subscriber)
      Subscriptions.subscribe(server, "news", subscriber)

      Process.exit(subscriber, :boom)

      assert_receive {:DOWN, ^ref, :process, ^subscriber, :boom}
      _ = :sys.get_state(server)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "no longer notifies it after it exits", %{server: server} do
      subscriber = spawn_subscriber()
      ref = Process.monitor(subscriber)
      Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      assert :ok = Subscriptions.publish(server, "news", :hello)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  # A process that stays alive until the test sends it :stop, or until the test ends.
  defp spawn_subscriber do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end
end
