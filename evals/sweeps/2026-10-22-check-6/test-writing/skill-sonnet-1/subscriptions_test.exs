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
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "start_link/1" do
    test "returns an error when no mailer is given", %{module: module, test: test} do
      name = Module.concat([module, test, "without mailer"])

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

    test "keeps subscribers of different topics apart", %{server: server} do
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

      Subscriptions.publish(server, "news", %{headline: "Hello"})

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "grace@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "ada@example.com")

      Subscriptions.publish(server, "news", :update)
      # a call is handled after the earlier publish cast
      Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "notifies a subscriber once per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:notification, "news", :update}
      refute_receive {:notification, _topic, _payload}
    end

    test "succeeds for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :update)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "ada@example.com")

      %{subscriber: subscriber}
    end

    test "removes it from the topic", %{server: server, subscriber: subscriber} do
      stop_process(subscriber)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps the other subscribers", %{server: server, subscriber: subscriber} do
      Subscriptions.subscribe(server, "news", self())

      stop_process(subscriber)

      assert Subscriptions.subscribers(server, "news") == [self(), "ada@example.com"]
    end

    test "removes it from every topic it subscribed to", %{server: server, subscriber: subscriber} do
      Subscriptions.subscribe(server, "sports", subscriber)

      stop_process(subscriber)

      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "still delivers to the remaining subscribers", %{server: server, subscriber: subscriber} do
      stop_process(subscriber)

      Subscriptions.publish(server, "news", :update)

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "keeps the server running when the process crashes", %{
      server: server,
      subscriber: subscriber
    } do
      stop_process(subscriber, :boom)

      assert Process.alive?(server)
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  # The server monitored the pid before the test did, so its :DOWN is queued before the next call.
  defp stop_process(pid, reason \\ :kill) do
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end
end
