ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  @registry Notify.SubscriptionsTest.Registry

  defmodule Mailer do
    @behaviour Notify.Mailer

    # Runs inside the server, so the server's registered name finds the test process.
    @impl true
    def deliver(to, subject) do
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

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Mailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds the pid to the subscribers of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      assert Subscriptions.subscribers(server, "orders") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")

      assert Subscriptions.subscribers(server, "orders") == ["ada@example.com"]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "orders", "grace@example.com")

      assert Subscriptions.subscribers(server, "orders") == [
               "grace@example.com",
               "ada@example.com"
             ]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3" do
    test "sends a notification tuple to a pid subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      :ok = Subscriptions.publish(server, "orders", %{id: 1})

      assert_receive {:notification, "orders", %{id: 1}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")

      :ok = Subscriptions.publish(server, "orders", %{id: 1})

      assert_receive {:delivered, "ada@example.com", "New on orders"}
    end

    test "notifies pid and email subscribers of the topic alike", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")

      :ok = Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:notification, "orders", :shipped}
      assert_receive {:delivered, "ada@example.com", "New on orders"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "orders", :shipped)

      # The call is handled after the cast, so the publish has been processed by now.
      assert Subscriptions.subscribers(server, "orders") == []
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "returns :ok and sends nothing when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "orders", :shipped)

      assert Subscriptions.subscribers(server, "orders") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", pid)
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "orders", "ada@example.com")

      await_exit(pid, fn -> send(pid, :stop) end)

      %{pid: pid}
    end

    test "removes the pid from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == ["ada@example.com"]
    end

    test "keeps mailing the email subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "orders", :shipped)

      assert_receive {:delivered, "ada@example.com", "New on orders"}
    end
  end

  describe "when a subscribed process is killed" do
    test "removes the pid from the subscribers", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", pid)

      await_exit(pid, fn -> Process.exit(pid, :kill) end)

      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  describe "when a pid is already dead at subscribe time" do
    test "does not keep the pid as a subscriber", %{server: server} do
      pid = spawn(fn -> :ok end)
      await_exit(pid, fn -> :ok end)

      :ok = Subscriptions.subscribe(server, "orders", pid)

      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  describe "when a process subscribed twice exits" do
    test "removes every subscription of the pid", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", pid)
      :ok = Subscriptions.subscribe(server, "orders", pid)

      await_exit(pid, fn -> send(pid, :stop) end)

      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp await_exit(pid, trigger) do
    ref = Process.monitor(pid)
    trigger.()
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
