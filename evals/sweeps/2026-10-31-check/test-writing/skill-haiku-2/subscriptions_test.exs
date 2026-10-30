ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so its registered name is the test's key
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.TestMailer.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, name, nil)
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})
    %{server: server}
  end

  describe "subscribe/3" do
    test "adds the pid to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["bob@example.com", "ann@example.com"]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "sport") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns pids and email addresses together", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify subscribers of another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", self()) == :ok
      assert Subscriptions.publish(server, "news", :goal) == :ok

      # The server handles the cast before it answers this call, so any
      # notification it sent is already in the mailbox.
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
    end

    test "delivers an email to an email subscriber through the mailer", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies a pid and an email subscriber of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.publish(server, "news", :hello) == :ok

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "returns :ok and keeps serving when the topic has no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "empty", :nobody) == :ok
      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sport", pid) == :ok

      stop_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      stop_subscriber(pid)
      assert Subscriptions.publish(server, "news", :again) == :ok

      assert_receive {:notification, "news", :again}
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_subscriber(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
