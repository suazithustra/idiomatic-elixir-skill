ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @moduledoc false
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      # deliver/2 runs inside the server, so the server's registered name is the test's key
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.SubscriptionsTest.Registry})
    :ok
  end

  setup %{test: test} do
    {:ok, _owner} = Registry.register(Notify.SubscriptionsTest.Registry, test, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: test})}
  end

  describe "subscribe/3" do
    test "adds a pid to the subscribers of its topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of its topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sport", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sport") == ["b@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "first@example.com")
      :ok = Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["second@example.com", "first@example.com"]
    end
  end

  describe "publish/3 to pid subscribers" do
    test "sends a notification to every subscribed pid", %{server: server} do
      test_pid = self()

      other =
        spawn(fn ->
          receive do
            msg -> send(test_pid, {:other, msg})
          end
        end)

      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", other)

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:other, {:notification, "news", :updated}}
    end

    test "does not notify pids subscribed to another topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sport", self())

      :ok = Subscriptions.publish(server, "news", :updated)

      # publish is a cast; this call is handled after it, so the notification would already be sent
      _ = Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails each subscribed address with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "does not mail addresses subscribed to another topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sport", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)
      _ = Subscriptions.subscribers(server, "news")

      refute_received {:delivered, _to, _subject}
    end

    test "notifies pids and mails addresses subscribed to the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      %{pid: pid}
    end

    test "removes the pid from the topic it was subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "removes the pid from every other topic it was subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the remaining subscribers notified", %{server: server} do
      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "reader@example.com", "New on news"}
    end
  end

  describe "when a subscribed process is killed" do
    test "removes the pid from its topic", %{server: server} do
      pid =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      :ok = Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end
  end
end
