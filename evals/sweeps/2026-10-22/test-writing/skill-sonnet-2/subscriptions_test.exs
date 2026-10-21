ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
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
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "start_link/1" do
    test "fails when no mailer is given", %{module: module, test: test} do
      name = Module.concat([module, test, "NoMailer"])

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child_spec}} =
               start_supervised(
                 Supervisor.child_spec({Subscriptions, name: name}, id: :no_mailer)
               )
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert [pid] = Subscriptions.subscribers(server, "news")
      assert pid == self()
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert ["a@example.com"] == Subscriptions.subscribers(server, "news")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert [] == Subscriptions.subscribers(server, "empty")
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert ["last@example.com", self(), "first@example.com"] ==
               Subscriptions.subscribers(server, "news")
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert ["a@example.com"] == Subscriptions.subscribers(server, "news")
      assert ["b@example.com"] == Subscriptions.subscribers(server, "sports")
    end
  end

  describe "publish/3" do
    test "sends a notification message to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")

      Subscriptions.publish(server, "news", :hello)
      # a synchronous call returns after the publish cast was handled
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert [] == Subscriptions.subscribers(server, "empty")
    end

    test "notifies a subscriber once per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:notification, "news", :hello}
      refute_receive {:notification, _topic, _payload}, 50
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)
      Subscriptions.subscribe(server, "news", "a@example.com")

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      # the server handles its own :DOWN message before this call
      :sys.get_state(server)
      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server} do
      assert ["a@example.com"] == Subscriptions.subscribers(server, "news")
      assert [] == Subscriptions.subscribers(server, "sports")
    end

    test "keeps the server running and notifying the other subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", "New on news"}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits normally" do
    test "removes it from the topic", %{server: server} do
      test_pid = self()

      subscriber =
        spawn(fn ->
          receive do
            :stop -> send(test_pid, :stopped)
          end
        end)

      Subscriptions.subscribe(server, "news", subscriber)
      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
      :sys.get_state(server)

      assert [] == Subscriptions.subscribers(server, "news")
    end
  end
end
