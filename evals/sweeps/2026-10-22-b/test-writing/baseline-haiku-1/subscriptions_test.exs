ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule Mailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      send(:subscriptions_test_probe, {:delivered, to, subject})
      :ok
    end
  end

  setup do
    # The mailer runs inside the server process, so it reports to a registered name.
    Process.register(self(), :subscriptions_test_probe)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, name: name, mailer: Mailer})

    %{server: name}
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns :ok and lists the email subscriber", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "lists the pid subscriber", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", "hello")
      assert_receive {:notification, "news", "hello"}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", "hello")
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies the subscribers of the published topic only", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "a@example.com", "New on news"}
      refute_receive {:notification, "sports", _}
      refute_receive {:delivered, "b@example.com", _}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", "hello")

      # publish/3 is a cast; a call afterwards guarantees it has been handled.
      assert Subscriptions.subscribers(server, "news") == []
      refute_receive {:notification, _, _}
      refute_receive {:delivered, _, _}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the topic's subscribers", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)

      stop(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      stop(pid)

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      stop(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "no longer receives publications and does not affect the others", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      stop(pid)
      assert :ok = Subscriptions.publish(server, "news", "after")

      assert_receive {:notification, "news", "after"}
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Waits for the process to exit. The server's :DOWN is enqueued when the process
  # dies, before the test's own :DOWN is delivered, so a call made afterwards sees
  # the subscriber already removed.
  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end
end
