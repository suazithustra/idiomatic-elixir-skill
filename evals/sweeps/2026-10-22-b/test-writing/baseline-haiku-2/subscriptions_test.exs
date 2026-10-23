ExUnit.start()

defmodule Notify.TestMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(:notify_test_mailer, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    # The mailer runs inside the server process, so it reaches the test through a registered name.
    Process.register(self(), :notify_test_mailer)
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer})
    %{server: server}
  end

  describe "subscribe/3 and subscribers/2" do
    test "lists subscribers of a topic, most recent first", %{server: server} do
      first = listener()
      second = listener()

      :ok = Subscriptions.subscribe(server, "news", first)
      :ok = Subscriptions.subscribe(server, "news", second)
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com", second, first]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      pid = listener()

      :ok = Subscriptions.subscribe(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == [pid]
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "unknown") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a process subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "sport", "goal")

      refute_receive {:notification, _, _}
    end

    test "delivers to an email subscriber through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "notifies process and email subscribers in the same publish", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "news", "hello")

      # A synchronous call after the cast guarantees the server has handled the publish.
      assert Subscriptions.subscribers(server, "news") == []
      refute_receive {:notification, _, _}
      refute_receive {:delivered, _, _}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the topic", %{server: server} do
      pid = listener()
      other = listener()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", other)

      kill_and_wait_for_removal(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == [other]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      pid = listener()
      other = listener()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)
      :ok = Subscriptions.subscribe(server, "sport", other)

      kill_and_wait_for_removal(server, "news", pid)
      eventually(fn -> Subscriptions.subscribers(server, "sport") == [other] end)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps email subscribers", %{server: server} do
      pid = listener()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      kill_and_wait_for_removal(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "no longer receives notifications, and the server keeps running", %{server: server} do
      pid = listener()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", self())

      kill_and_wait_for_removal(server, "news", pid)

      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert Process.alive?(server)
    end

    test "is removed on subscribe when it was already dead", %{server: server} do
      pid = dead_process()

      :ok = Subscriptions.subscribe(server, "news", pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  # Kills `pid` and waits until the server has dropped it from `topic`.
  defp kill_and_wait_for_removal(server, topic, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    eventually(fn -> pid not in Subscriptions.subscribers(server, topic) end)
  end

  # Polls until `fun` returns true, since the server handles DOWN messages asynchronously.
  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition was not met in time")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  defp listener do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp dead_process do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end
end
