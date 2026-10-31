ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so the server's registered name is the key under
  # which the test process registered itself.
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

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    assert {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
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
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self(), "ana@example.com"]
    end

    test "lists only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "sports") == ["ana@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "news", %{title: "Election results"})
      assert_receive {:notification, "news", %{title: "Election results"}}
    end

    test "mails a subscribed address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      Subscriptions.publish(server, "news", %{title: "Election results"})
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "sports", %{title: "Final score"})
      Subscriptions.publish(server, "news", %{title: "Election results"})
      assert_receive {:notification, "news", _payload}
      refute_received {:notification, "sports", _payload}
    end
  end

  describe "when a subscribed process has exited" do
    setup %{server: server} do
      subscriber = start_supervised!({Agent, fn -> nil end})
      ref = Process.monitor(subscriber)
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert [^subscriber] = Subscriptions.subscribers(server, "news")
      assert stop_supervised(Agent) == :ok
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :shutdown}
      :ok
    end

    test "subscribers/2 no longer lists it", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "publish/3 still reaches the remaining subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "news", %{title: "Election results"})
      assert_receive {:notification, "news", %{title: "Election results"}}
    end
  end
end
