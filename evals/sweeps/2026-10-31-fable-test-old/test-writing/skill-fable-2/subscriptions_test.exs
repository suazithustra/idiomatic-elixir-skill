ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  def registry, do: @registry

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
  alias Notify.TestMailer

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
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ops@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{title: "Release 2.0"}) == :ok

      assert_receive {:notification, "news", %{title: "Release 2.0"}}
    end

    test "mails a subscribed address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.publish(server, "news", %{title: "Release 2.0"}) == :ok

      assert_receive {:delivered, "ops@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.publish(server, "news", :published) == :ok

      assert_receive {:notification, "news", :published}
      assert_receive {:delivered, "ops@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.publish(server, "sports", :published) == :ok

      assert Subscriptions.subscribers(server, "sports") == []
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "first@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "second@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") ==
               [self(), "second@example.com", "first@example.com"]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ops@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ops@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes the process from every topic it subscribed to", %{server: server} = context do
      refute context.exited in Subscriptions.subscribers(server, "news")
      refute context.exited in Subscriptions.subscribers(server, "sports")
    end

    test "keeps the other subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ops@example.com", self()]
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    ref = Process.monitor(subscriber)

    :ok = Subscriptions.subscribe(server, "news", self())
    :ok = Subscriptions.subscribe(server, "news", subscriber)
    :ok = Subscriptions.subscribe(server, "news", "ops@example.com")
    :ok = Subscriptions.subscribe(server, "sports", subscriber)

    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

    %{exited: subscriber}
  end
end
