ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the server, so the server's registered name is the key the test registered under.
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
    test "makes the pid a subscriber of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "makes an email address a subscriber of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "publish/3 to a process subscriber" do
    test "sends a notification to the subscribed process", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
    end

    test "does not notify a process subscribed to another topic", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())

      Subscriptions.publish(server, "news", :miss)
      Subscriptions.publish(server, "sports", :hit)

      # Both casts come from this process, so a notification for "news" would arrive first.
      assert_receive {:notification, "sports", :hit}
      refute_received {:notification, "news", _payload}
    end

    test "notifies a process and an email address subscribed to the same topic",
         %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  describe "publish/3 to an email subscriber" do
    test "delivers the subject through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not deliver to an address subscribed to another topic", %{server: server} do
      Subscriptions.subscribe(server, "sports", "ada@example.com")

      Subscriptions.publish(server, "news", :miss)
      Subscriptions.publish(server, "sports", :hit)

      assert_receive {:delivered, "ada@example.com", "New on sports"}
      refute_received {:delivered, _to, "New on news"}
    end
  end

  describe "subscribers/2" do
    test "lists subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "grace@example.com")
      Subscriptions.subscribe(server, "news", "alan@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "alan@example.com",
               "grace@example.com",
               "ada@example.com"
             ]
    end

    test "lists only the subscribers of the given topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "sports", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "weather") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid = spawn(fn -> receive do _message -> :ok end end)
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)
      %{pid: pid}
    end

    test "removes the exited pid from every topic it subscribed to", %{
      server: server,
      pid: pid
    } do
      kill_and_wait(pid)

      # The server handles the :DOWN from this same exit before this call returns.
      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, pid: pid} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      kill_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
