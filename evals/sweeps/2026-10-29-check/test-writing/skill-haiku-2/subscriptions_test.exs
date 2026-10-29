ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Notify.Subscriptions

  @registry Notify.SubscriptionsTest.Registry

  defmodule Mailer do
    @moduledoc false
    @behaviour Notify.Mailer

    # Runs inside the server, so the server's registered name is the test's key
    @impl true
    def deliver(to, subject) do
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    server = start_supervised!({Subscriptions, mailer: Mailer, name: name})
    %{server: server}
  end

  describe "start_link/1" do
    test "fails to start without a :mailer option", context do
      name = Module.concat(context.module, :without_mailer)

      capture_log(fn ->
        assert {:error, _reason} = start_supervised({Subscriptions, name: name})
      end)
    end
  end

  describe "subscribe/3" do
    test "adds the subscriber to the topic and returns :ok", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "sport") == []
    end
  end

  describe "publish/3" do
    test "sends {:notification, topic, payload} to a pid subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
    end

    test "delivers an email through the mailer to an email subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies both pid and email subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "sport", :final) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      # The server handles casts in order, so a "sport" notification would already be in the mailbox
      assert_receive {:notification, "news", :updated}
      refute_received {:notification, "sport", _payload}
    end
  end

  describe "subscribers/2" do
    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "b@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", "a@example.com"]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    test "removes the pid from the topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      exit_normally(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the pid from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sport", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      kill(pid)

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the email subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok

      kill(pid)

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "keeps the server running and still notifies the other subscribers", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      kill(pid)
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert Process.alive?(server)
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :exit -> :ok
      end
    end)
  end

  defp exit_normally(pid) do
    ref = Process.monitor(pid)
    send(pid, :exit)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
