ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  def registry, do: @registry

  # deliver/2 runs inside the server, so its registered name is the key the test
  # registered itself under.
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
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: name}
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

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ana@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "news", %{headline: "Elixir 1.20 released"})
      assert_receive {:notification, "news", %{headline: "Elixir 1.20 released"}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      Subscriptions.publish(server, "news", %{headline: "Elixir 1.20 released"})
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      Subscriptions.publish(server, "news", :headline)
      assert_receive {:notification, "news", :headline}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "sports", :match_report)
      Subscriptions.publish(server, "news", :headline)

      # The server sends both messages in order, so once the news notification has
      # arrived a sports notification would already be in the mailbox.
      assert_receive {:notification, "news", :headline}
      refute_received {:notification, "sports", _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
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

    test "removes it from the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :headline)
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Task, &wait_for_stop/0})
    ref = Process.monitor(subscriber)
    assert Subscriptions.subscribe(server, "news", subscriber) == :ok
    assert Subscriptions.subscribe(server, "sports", subscriber) == :ok
    assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
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
