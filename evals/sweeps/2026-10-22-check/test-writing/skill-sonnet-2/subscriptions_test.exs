ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @registry __MODULE__.Registry

  def registry, do: @registry

  # deliver/2 runs inside the server, so its registered name is the test's key
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
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.registry()})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.registry(), name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps subscriptions to different topics apart", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a process subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      Subscriptions.publish(server, "news", :hello)
      # a call is handled after the publish cast, so the cast has been processed
      Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _topic, _payload}, 0
      refute_receive {:delivered, _to, _subject}, 0
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :hello)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", self())

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
      assert Subscriptions.subscribers(server, "news") == [self(), "ada@example.com"]
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  describe "when a subscribed process is killed" do
    test "removes it from the topic", %{server: server} do
      subscriber = spawn(fn -> receive do: (:never -> :ok) end)
      Subscriptions.subscribe(server, "news", subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end
  end
end
