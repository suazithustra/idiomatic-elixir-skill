ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    # deliver/2 runs inside the server, so its registered name is the test's key
    @impl true
    def deliver(to, subject) do
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  defp spawn_idle_process do
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

  describe "start_link/1" do
    test "fails without a :mailer option", %{module: module, test: test} do
      name = Module.concat([module, test, "NoMailer"])

      spec = Supervisor.child_spec({Subscriptions, name: name}, id: :no_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} =
               start_supervised(spec)
    end
  end

  describe "subscribe/3" do
    test "adds a pid subscriber to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert [pid] = Subscriptions.subscribers(server, "news")
      assert pid == self()
    end

    test "adds an email subscriber to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      assert ["ann@example.com"] = Subscriptions.subscribers(server, "news")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert [] = Subscriptions.subscribers(server, "empty")
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")

      assert ["second@example.com", "first@example.com"] =
               Subscriptions.subscribers(server, "news")
    end

    test "keeps each topic's subscribers apart", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert ["ann@example.com"] = Subscriptions.subscribers(server, "news")
      assert ["bob@example.com"] = Subscriptions.subscribers(server, "sports")
    end

    test "lists pids and emails together", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self(), "ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", :ignored)
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", "bob@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      Subscriptions.publish(server, "news", :hello)
      # a synchronous call returns only after the cast was handled
      :sys.get_state(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "keeps the server running for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      :sys.get_state(server)

      assert Process.alive?(server)
      assert [] = Subscriptions.subscribers(server, "empty")
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn_idle_process()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "sports", subscriber)
      Subscriptions.subscribe(server, "sports", self())

      stop_and_wait(subscriber)
      # the server has handled its own :DOWN message once it answers this call
      :sys.get_state(server)

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server, subscriber: subscriber} do
      refute subscriber in Subscriptions.subscribers(server, "news")
      refute subscriber in Subscriptions.subscribers(server, "sports")
    end

    test "keeps the other subscribers", %{server: server} do
      assert ["ann@example.com"] = Subscriptions.subscribers(server, "news")
      assert [pid] = Subscriptions.subscribers(server, "sports")
      assert pid == self()
    end

    test "keeps publishing to the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :after_exit)
      Subscriptions.publish(server, "sports", :after_exit)

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:notification, "sports", :after_exit}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process is killed" do
    test "removes it from the topic", %{server: server} do
      subscriber = spawn_idle_process()
      Subscriptions.subscribe(server, "news", subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}
      :sys.get_state(server)

      assert [] = Subscriptions.subscribers(server, "news")
    end
  end
end
