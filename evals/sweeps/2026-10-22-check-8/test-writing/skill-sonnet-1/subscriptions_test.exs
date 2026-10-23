ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

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
    test "fails when no mailer is given", context do
      name = Module.concat(context.module, "#{context.test} without mailer")

      child_spec = Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} =
               start_supervised(child_spec)
    end
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

    test "keeps the topics apart", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "sports", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["grace@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["grace@example.com", self(), "ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{headline: "Hello"})

      assert_receive {:notification, "news", %{headline: "Hello"}}
    end

    test "mails a subscribed email address", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      assert :ok = Subscriptions.publish(server, "news", %{headline: "Hello"})

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies pids and email addresses of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "sends one notification per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:notification, "news", :update}
      refute_receive {:notification, _topic, _payload}, 50
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "grace@example.com")

      Subscriptions.publish(server, "news", :update)
      # a synchronous call returns only after the publish cast was handled
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "returns :ok for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :update)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_and_exit]

    test "is removed from the topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "is removed from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "does not stop the remaining subscribers from being notified", %{server: server} do
      Subscriptions.publish(server, "news", :update)

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  describe "when a subscribed process crashes" do
    test "is removed from the topic", %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(subscriber)
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = spawn(fn -> receive(do: (:stop -> :ok)) end)
    ref = Process.monitor(subscriber)

    Subscriptions.subscribe(server, "news", subscriber)
    Subscriptions.subscribe(server, "news", "ada@example.com")
    Subscriptions.subscribe(server, "sports", subscriber)

    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

    %{subscriber: subscriber}
  end
end
