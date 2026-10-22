ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Notify.Subscriptions

  defmodule FakeMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      send(:notify_test_mailbox, {:delivered, to, subject})
      :ok
    end
  end

  setup do
    # The mailer runs inside the server process, so it reports back to a registered name.
    Process.register(self(), :notify_test_mailbox)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    server = start_supervised!({Subscriptions, mailer: FakeMailer, name: name})

    %{server: server}
  end

  # Calls and casts from one process are handled in order, so once this returns
  # every cast sent before it has been handled.
  defp sync(server), do: :sys.get_state(server)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp spawn_idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  describe "start_link/1" do
    test "registers under Notify.Subscriptions when no :name is given" do
      pid = start_supervised!(Supervisor.child_spec({Subscriptions, mailer: FakeMailer}, id: :default_named))

      assert Process.whereis(Subscriptions) == pid

      :ok = Subscriptions.subscribe("news", self())
      Subscriptions.publish("news", :hello)

      assert_receive {:notification, "news", :hello}
    end

    test "fails to start without a :mailer" do
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:error, _reason} = Subscriptions.start_link(name: :no_mailer_test)
      end)
    end
  end

  describe "subscribe/3" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists pid and email subscribers, most recent first", %{server: server} do
      other = spawn_idle_process()

      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      :ok = Subscriptions.subscribe(server, "news", other)

      assert Subscriptions.subscribers(server, "news") == [other, "reader@example.com", self()]
    end
  end

  describe "publish/3" do
    test "sends a notification to pid subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "emails email subscribers through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      Subscriptions.publish(server, "news", "payload")

      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the topic together", %{server: server} do
      other = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      :ok = Subscriptions.subscribe(server, "news", other)

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "reader@example.com", "New on news"}
      stop_and_wait(other)
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      Subscriptions.publish(server, "sports", :score)
      sync(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :nobody_home)
      sync(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it after a normal exit", %{server: server} do
      pid = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", pid)

      stop_and_wait(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes it after it is killed", %{server: server} do
      pid = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", pid)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      pid = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sports", pid)

      stop_and_wait(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      gone = spawn_idle_process()
      stays = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", stays)
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      :ok = Subscriptions.subscribe(server, "news", gone)

      stop_and_wait(gone)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["reader@example.com", stays] end)
    end

    test "does not notify the rest of the topic after the exit", %{server: server} do
      gone = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", gone)
      :ok = Subscriptions.subscribe(server, "news", self())

      stop_and_wait(gone)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after_exit)

      assert_receive {:notification, "news", :after_exit}
    end

    test "leaves the server running", %{server: server} do
      pid = spawn_idle_process()
      :ok = Subscriptions.subscribe(server, "news", pid)

      stop_and_wait(pid)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)

      assert Process.alive?(server)
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end
  end
end
