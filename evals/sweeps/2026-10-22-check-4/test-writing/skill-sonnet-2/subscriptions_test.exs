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

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "start_link/1" do
    test "fails when no mailer is given", context do
      name = Module.concat([context.module, context.test, WithoutMailer])

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child_spec}} =
               start_supervised(Supervisor.child_spec({Subscriptions, name: name}, id: name))
    end
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
      Subscriptions.subscribe(server, "sports", "ann@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ann@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies both kinds of subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", :breaking)

      assert_receive {:notification, "news", :breaking}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "ann@example.com")

      Subscriptions.publish(server, "news", :breaking)
      # a synchronous call returns only after the publish cast was handled
      Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _topic, _payload}, 0
      refute_receive {:delivered, _to, _subject}, 0
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :breaking)
      assert Subscriptions.subscribers(server, "news") == []
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process has exited" do
    setup %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "sports", subscriber)

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps publishing to the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :breaking)

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end
  end

  describe "when a subscribed process is killed" do
    test "removes it from the topic", %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert Subscriptions.subscribers(server, "news") == []
      assert Process.alive?(server)
    end
  end
end
