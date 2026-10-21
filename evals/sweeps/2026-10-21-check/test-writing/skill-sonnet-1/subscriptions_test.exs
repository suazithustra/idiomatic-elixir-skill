ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
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

  setup %{test: name} do
    {:ok, _owner} = Registry.register(TestMailer.registry(), name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "start_link/1" do
    test "requires a mailer", %{test: name} do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _stacktrace}} =
               Subscriptions.start_link(name: :"#{name} without mailer")
    end
  end

  describe "subscribe/3" do
    test "adds a pid and an email address to a topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      assert ["ann@example.com", self()] == Subscriptions.subscribers(server, "news")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert [] == Subscriptions.subscribers(server, "empty")
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")

      assert ["second@example.com", "first@example.com"] ==
               Subscriptions.subscribers(server, "news")
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert ["ann@example.com"] == Subscriptions.subscribers(server, "news")
      assert ["bob@example.com"] == Subscriptions.subscribers(server, "sports")
    end
  end

  describe "publish/3" do
    test "sends a notification message to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", "bob@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      Subscriptions.publish(server, "news", :update)
      # a call is handled after the earlier publish cast
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :update)
      assert [] == Subscriptions.subscribers(server, "empty")
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      stayer = "ann@example.com"
      pid = spawn(fn -> receive(do: (:stop -> :ok)) end)
      ref = Process.monitor(pid)

      Subscriptions.subscribe(server, "news", stayer)
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)
      Subscriptions.subscribe(server, "sports", self())

      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      %{exited: pid}
    end

    test "removes it from every topic", %{server: server} do
      assert ["ann@example.com"] == Subscriptions.subscribers(server, "news")
      assert [self()] == Subscriptions.subscribers(server, "sports")
    end

    test "keeps the server running", %{server: server} do
      assert Process.alive?(server)
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :update)
      Subscriptions.publish(server, "sports", :update)

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:notification, "sports", :update}
    end
  end
end

