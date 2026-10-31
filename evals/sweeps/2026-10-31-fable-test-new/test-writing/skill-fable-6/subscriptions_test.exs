ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the test's key.
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
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com", self()]
    end

    test "lists only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "news", %{headline: "Election called"})
      assert_receive {:notification, "news", %{headline: "Election called"}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      Subscriptions.publish(server, "news", %{headline: "Election called"})
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      Subscriptions.publish(server, "news", %{headline: "Election called"})
      assert_receive {:notification, "news", %{headline: "Election called"}}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "leaves the subscribers of other topics alone", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "sports", %{headline: "Match started"})
      Subscriptions.publish(server, "news", %{headline: "Election called"})
      assert_receive {:notification, "news", %{headline: "Election called"}}
      refute_received {:notification, "sports", _payload}
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "it is removed from the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "it is removed from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "publishing still reaches the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", %{headline: "Election called"})
      assert_receive {:notification, "news", %{headline: "Election called"}}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(subscriber)
    :ok = Subscriptions.subscribe(server, "news", subscriber)
    :ok = Subscriptions.subscribe(server, "sports", subscriber)
    :ok = Subscriptions.subscribe(server, "news", self())
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
    :ok
  end
end
