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
    assert {:ok, _owner} = Registry.register(TestMailer.registry(), name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "subscribes to one topic only", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self(), "ana@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert Subscriptions.publish(server, "sports", %{id: 2}) == :ok
      assert_receive {:notification, "sports", %{id: 2}}
      refute_received {:notification, "news", _payload}
    end

    test "leaves the server running when the topic has no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Task, &wait_for_stop/0})
    assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
    assert Subscriptions.subscribe(server, "news", subscriber) == :ok
    assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
    :ok
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end
end
