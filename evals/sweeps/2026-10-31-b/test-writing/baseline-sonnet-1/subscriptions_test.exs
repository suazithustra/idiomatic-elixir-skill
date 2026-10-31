ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    # Reports each delivery to the test process registered in the application env.
    @impl true
    def deliver(to, subject) do
      send(Application.fetch_env!(:notify_test, :mailer_listener), {:delivered, to, subject})
      :ok
    end
  end

  setup do
    Application.put_env(:notify_test, :mailer_listener, self())
    on_exit(fn -> Application.delete_env(:notify_test, :mailer_listener) end)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: name}
  end

  # A process that stays alive until told to stop, so tests control when it exits.
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
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # Waits until the server has processed all messages sent so far.
  defp sync(server), do: :sys.get_state(server)

  describe "start_link/1" do
    test "requires a :mailer option" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = Subscriptions.start_link(name: :no_mailer_subscriptions)
    end

    test "registers under the given name", %{server: server} do
      assert is_pid(Process.whereis(server))
    end
  end

  describe "subscribe/3" do
    test "returns :ok for a pid and for an email", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
    end

    test "uses the default name when none is given" do
      start_supervised!({Subscriptions, mailer: TestMailer}, id: :default_named)

      assert :ok = Subscriptions.subscribe("default-topic", self())
      assert Subscriptions.subscribers("default-topic") == [self()]
    end
  end

  describe "subscribers/2" do
    test "is empty for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "lists subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "a", "a@example.com")
      Subscriptions.subscribe(server, "b", "b@example.com")

      assert Subscriptions.subscribers(server, "a") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "b") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to pid subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers with a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert :ok = Subscriptions.publish(server, "news", :ignored)
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber of both kinds", %{server: server} do
      other = spawn_subscriber()
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "other", self())
      Subscriptions.subscribe(server, "other", "other@example.com")
      Subscriptions.subscribe(server, "news", "news@example.com")

      Subscriptions.publish(server, "news", :hello)
      sync(server)

      assert_received {:delivered, "news@example.com", _}
      refute_received {:notification, _, _}
      refute_received {:delivered, "other@example.com", _}
    end

    test "to a topic without subscribers does nothing", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :hello)
      sync(server)

      refute_received _
      assert Process.alive?(Process.whereis(server))
    end

    test "delivers each publish separately", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      stop_and_wait(pid)
      sync(server)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "it is removed from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      stop_and_wait(pid)
      sync(server)

      assert Subscriptions.subscribers(server, "a") == []
      assert Subscriptions.subscribers(server, "b") == []
    end

    test "it is removed when the process crashes", %{server: server} do
      pid = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :crash)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}
      sync(server)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "other subscribers are kept, in order", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      stop_and_wait(pid)
      sync(server)

      assert Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
    end

    test "publishing afterwards still reaches the remaining subscribers", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      stop_and_wait(pid)
      sync(server)
      Subscriptions.publish(server, "news", :after_exit)

      assert_receive {:notification, "news", :after_exit}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "the server keeps running", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      stop_and_wait(pid)
      sync(server)

      assert Process.alive?(Process.whereis(server))
    end
  end
end
