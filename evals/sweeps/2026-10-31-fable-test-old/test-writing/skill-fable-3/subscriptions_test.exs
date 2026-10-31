ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the key the test
  # registered itself under.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.TestMailer.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.TestMailer

  @article %{title: "Elixir 1.20 released"}

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a process to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "leaves other topics untouched", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", @article) == :ok
      assert_receive {:notification, "news", @article}
    end

    test "mails a subscribed email address with the topic as subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.publish(server, "news", @article) == :ok
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", @article) == :ok
      assert_receive {:notification, "news", @article}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies only the subscribers of the published topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "sports", @article) == :ok
      assert Subscriptions.publish(server, "news", @article) == :ok
      assert_receive {:notification, "news", @article}
      refute_received {:notification, "sports", _payload}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", @article) == :ok
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self(), "ana@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes the process from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", @article) == :ok
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
