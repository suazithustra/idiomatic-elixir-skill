ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, whose test-specific name is the registry key
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Mailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Mailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Mailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "keeps subscribers of other topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "bo@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bo@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "bo@example.com") == :ok

      expected = ["bo@example.com", self(), "ana@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "bo@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      # the call waits until the publish cast has been handled
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_other_process_and_email, :stop_other_process]

    test "removes the process from the topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "removes the process from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "leaves the server running", %{server: server} do
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process is killed" do
    test "removes the process from the topic", %{server: server} do
      pid = start_idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  defp subscribe_other_process_and_email(%{server: server}) do
    pid = start_idle_process()

    assert Subscriptions.subscribe(server, "news", pid) == :ok
    assert Subscriptions.subscribe(server, "sports", pid) == :ok
    assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

    %{pid: pid}
  end

  defp stop_other_process(%{pid: pid}) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    :ok
  end

  defp start_idle_process do
    start_supervised!(
      Supervisor.child_spec({Task, &wait_for_stop/0}, id: make_ref(), restart: :temporary)
    )
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end
end
