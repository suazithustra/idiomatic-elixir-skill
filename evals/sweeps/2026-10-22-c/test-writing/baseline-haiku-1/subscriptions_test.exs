ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(Process.whereis(:notify_test_mail), {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    # The mailer runs inside the server process, so it reports to a registered
    # name that the test process owns.
    Process.register(self(), :notify_test_mail)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})

    %{server: name}
  end

  describe "subscribe/3" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "accepts an email address", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      assert ["reader@example.com"] = Subscriptions.subscribers(server, "news")
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sport", "b@example.com")

      assert ["a@example.com"] = Subscriptions.subscribers(server, "news")
      assert ["b@example.com"] = Subscriptions.subscribers(server, "sport")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert [] = Subscriptions.subscribers(server, "unknown")
    end

    test "lists the most recent subscriber first", %{server: server} do
      first = spawn_sleeper()
      second = spawn_sleeper()

      :ok = Subscriptions.subscribe(server, "news", first)
      :ok = Subscriptions.subscribe(server, "news", second)

      assert [^second, ^first] = Subscriptions.subscribers(server, "news")
    end

    test "lists pids and email addresses together", %{server: server} do
      pid = spawn_sleeper()

      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      assert ["reader@example.com", ^pid] = Subscriptions.subscribers(server, "news")
    end
  end

  describe "publish/3 with pid subscribers" do
    test "sends a notification to the subscribed pid", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      publish_and_wait(server, "news", "hello")

      assert_received {:notification, "news", "hello"}
    end

    test "notifies every pid subscribed to the topic", %{server: server} do
      test_pid = self()
      other = spawn(fn -> forward_next(test_pid) end)

      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", other)

      publish_and_wait(server, "news", "hello")

      assert_received {:notification, "news", "hello"}
      assert_receive {:forwarded, {:notification, "news", "hello"}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      publish_and_wait(server, "sport", "goal")

      refute_received {:notification, _, _}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      publish_and_wait(server, "news", "hello")

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end
  end

  describe "publish/3 with email subscribers" do
    test "delivers the payload's topic as the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      publish_and_wait(server, "news", "hello")

      assert_received {:delivered, "reader@example.com", "New on news"}
    end

    test "delivers to every email address on the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      publish_and_wait(server, "news", "hello")

      assert_received {:delivered, "a@example.com", "New on news"}
      assert_received {:delivered, "b@example.com", "New on news"}
    end

    test "notifies pid and email subscribers in the same publish", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      publish_and_wait(server, "news", "hello")

      assert_received {:notification, "news", "hello"}
      assert_received {:delivered, "reader@example.com", "New on news"}
    end
  end

  describe "subscriber exit" do
    test "removes a pid that was killed", %{server: server} do
      pid = spawn_sleeper()
      :ok = Subscriptions.subscribe(server, "news", pid)

      kill_and_wait(pid)

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes a pid that exited normally", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      :ok = Subscriptions.subscribe(server, "news", pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes the exited pid from every topic", %{server: server} do
      pid = spawn_sleeper()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)

      kill_and_wait(pid)

      assert_eventually(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sport") == []
      end)
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      dead = spawn_sleeper()
      :ok = Subscriptions.subscribe(server, "news", dead)
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      kill_and_wait(dead)

      assert_eventually(fn ->
        Subscriptions.subscribers(server, "news") == ["reader@example.com", self()]
      end)
    end

    test "no longer notifies the exited pid", %{server: server} do
      test_pid = self()
      pid = spawn(fn -> forward_next(test_pid) end)
      :ok = Subscriptions.subscribe(server, "news", pid)

      kill_and_wait(pid)
      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)

      publish_and_wait(server, "news", "hello")

      refute_received {:forwarded, _}
    end

    test "keeps delivering email after a pid subscriber exits", %{server: server} do
      pid = spawn_sleeper()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      kill_and_wait(pid)
      assert_eventually(fn -> Subscriptions.subscribers(server, "news") == ["reader@example.com"] end)

      publish_and_wait(server, "news", "hello")

      assert_received {:delivered, "reader@example.com", "New on news"}
    end
  end

  describe "start_link/1" do
    @tag :capture_log
    test "fails to start without a :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _stacktrace}} =
               Subscriptions.start_link(name: :"no_mailer_#{System.unique_integer([:positive])}")
    end
  end

  # Publish is a cast, so a call from the same process to the server returns
  # only after the cast has been handled.
  defp publish_and_wait(server, topic, payload) do
    :ok = Subscriptions.publish(server, topic, payload)
    _ = Subscriptions.subscribers(server, topic)
    :ok
  end

  defp spawn_sleeper do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp forward_next(test_pid) do
    receive do
      msg -> send(test_pid, {:forwarded, msg})
    end
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
