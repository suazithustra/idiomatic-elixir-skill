ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # The server calls deliver/2, so its registered name is the key the test registered under
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, nil}] = Registry.lookup(Notify.TestMailer.Registry, server)
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
    # The server is named after the test, so the mailer can route deliveries back to it
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, name, nil)

    %{server: start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds the subscriber to the topic and returns :ok", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:notification, "news", :launched}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:delivered, "ops@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      # publish/3 is a cast; reading the state returns only after the server handled it
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ops@example.com", self()]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "fans@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["fans@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from every topic it subscribed to", %{server: server} do
      pid = start_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sports", pid) == :ok

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes it when it is killed", %{server: server} do
      pid = start_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other subscribers of the topic and still notifies them", %{server: server} do
      pid = start_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert Subscriptions.subscribers(server, "news") == ["ops@example.com", self()]

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:notification, "news", :launched}
      assert_receive {:delivered, "ops@example.com", "New on news"}
    end
  end

  defp start_subscriber do
    start_supervised!({Task, &wait_for_stop/0})
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end
end
