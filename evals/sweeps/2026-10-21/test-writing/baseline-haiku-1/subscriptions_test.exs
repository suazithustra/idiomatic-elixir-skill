ExUnit.start()

defmodule Notify.SubscriptionsTest.FakeMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Reports each delivery to the test process registered as :mail_probe.
  @impl true
  def deliver(to, subject) do
    send(:mail_probe, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.FakeMailer

  setup do
    # The mailer runs inside the server process, so it reaches the test through a registered name.
    Process.register(self(), :mail_probe)
    %{server: start_server()}
  end

  describe "subscribe/3" do
    test "returns :ok and records the subscriber under the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.subscribers(server, "sport") == []
    end
  end

  describe "publish/3 with pid subscribers" do
    test "sends a notification message to the subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
    end

    test "notifies every pid subscribed to the topic", %{server: server} do
      test_pid = self()
      other = spawn(fn -> receive do msg -> send(test_pid, {:forwarded, msg}) end end)

      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)
      Subscriptions.publish(server, "news", "hi")

      assert_receive {:notification, "news", "hi"}
      assert_receive {:forwarded, {:notification, "news", "hi"}}
    end

    test "does not notify pids subscribed to a different topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "sport", "goal")

      refute_receive {:notification, _, _}, 100
    end

    test "publishing to a topic with no subscribers is harmless", %{server: server} do
      assert Subscriptions.publish(server, "news", "nobody home") == :ok

      # A call after the cast returns only once the server has handled the publish.
      assert Subscriptions.subscribers(server, "news") == []
      assert Process.alive?(GenServer.whereis(server))
    end
  end

  describe "publish/3 with email subscribers" do
    test "delivers through the mailer with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "delivers to each email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", "bob@example.com")
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "delivers to email and pid subscribers in the same publish", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not call the mailer for a different topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.publish(server, "sport", "goal")

      refute_receive {:delivered, _, _}, 100
    end
  end

  describe "subscriber exit" do
    test "removes an exited pid from its topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)

      exit_and_wait_for_down(pid, :killed)

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") end, [])
    end

    test "removes an exited pid from every topic it subscribed to", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sport", pid)

      exit_and_wait_for_down(pid, :killed)

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") end, [])
      assert_eventually(fn -> Subscriptions.subscribers(server, "sport") end, [])
    end

    test "removes a pid that exits normally", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") end, [])
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      gone = spawn_idle()
      Subscriptions.subscribe(server, "news", gone)
      Subscriptions.subscribe(server, "news", self())

      exit_and_wait_for_down(gone, :killed)

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") end, [self()])
    end

    test "keeps email subscribers", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", pid)

      exit_and_wait_for_down(pid, :killed)

      assert_eventually(
        fn -> Subscriptions.subscribers(server, "news") end,
        ["ann@example.com"]
      )
    end

    test "an exited pid is not notified after it is removed", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      exit_and_wait_for_down(pid, :killed)
      assert_eventually(fn -> Subscriptions.subscribers(server, "news") end, [])

      Subscriptions.publish(server, "news", "late")

      # Synchronize with the server before checking the mailbox.
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _, _}
      assert Process.alive?(GenServer.whereis(server))
    end

    test "publishing still reaches live subscribers after another subscriber exits", %{
      server: server
    } do
      gone = spawn_idle()
      Subscriptions.subscribe(server, "news", gone)
      Subscriptions.subscribe(server, "news", self())

      exit_and_wait_for_down(gone, :killed)
      assert_eventually(fn -> Subscriptions.subscribers(server, "news") end, [self()])

      Subscriptions.publish(server, "news", "still here")

      assert_receive {:notification, "news", "still here"}
    end
  end

  # Starts an isolated server under a unique name so tests do not share state.
  defp start_server(opts \\ []) do
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, Keyword.merge([mailer: FakeMailer, name: name], opts)})
    name
  end

  # A process that stays alive until it is told to stop or killed.
  defp spawn_idle do
    spawn(fn -> receive do :stop -> :ok end end)
  end

  defp exit_and_wait_for_down(pid, reason) do
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
  end

  # The server handles :DOWN messages asynchronously, so poll until the list settles.
  defp assert_eventually(fun, expected, attempts \\ 50) do
    result = fun.()

    cond do
      result == expected -> :ok
      attempts == 0 -> assert result == expected
      true ->
        Process.sleep(10)
        assert_eventually(fun, expected, attempts - 1)
    end
  end
end
