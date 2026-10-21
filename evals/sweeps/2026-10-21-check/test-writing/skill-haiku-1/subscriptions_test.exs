ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  @impl true
  def deliver(to, subject) do
    # The server calls deliver/2 inside its own process, so the test is found by the server's name
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(@registry, server)
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

  setup %{test: name} do
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, name, nil)
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})
    %{server: name}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic and returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "orders", self())
      assert Subscriptions.subscribers(server, "orders") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", "first@example.com")
      :ok = Subscriptions.subscribe(server, "orders", "second@example.com")

      assert Subscriptions.subscribers(server, "orders") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "keeps subscriptions to different topics apart", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())

      assert Subscriptions.subscribers(server, "refunds") == []
    end
  end

  describe "publish/3" do
    test "sends the payload to a pid subscriber and mails an email subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "orders", self())
      :ok = Subscriptions.subscribe(server, "orders", "ana@example.com")

      assert :ok = Subscriptions.publish(server, "orders", %{id: 1})

      assert_receive {:notification, "orders", %{id: 1}}
      assert_receive {:delivered, "ana@example.com", "New on orders"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "refunds", self())

      :ok = Subscriptions.publish(server, "orders", :created)
      # The server handles the cast before this call and sends any notification before replying,
      # so a notification would already be in the mailbox here.
      _ = Subscriptions.subscribers(server, "orders")

      refute_received {:notification, _topic, _payload}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      pid = Process.whereis(server)

      assert :ok = Subscriptions.publish(server, "nobody", :created)
      assert Subscriptions.subscribers(server, "nobody") == []
      assert Process.whereis(server) == pid
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nobody") == []
    end
  end

  describe "when a subscribed process exits" do
    test "removes the pid from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", pid)
      :ok = Subscriptions.subscribe(server, "refunds", pid)

      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "orders") == []
      assert Subscriptions.subscribers(server, "refunds") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "orders", pid)
      :ok = Subscriptions.subscribe(server, "orders", "ana@example.com")

      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "orders") == ["ana@example.com"]
    end

    test "removes a pid that had already exited when it subscribed", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      :ok = Subscriptions.subscribe(server, "orders", pid)

      assert Subscriptions.subscribers(server, "orders") == []
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
