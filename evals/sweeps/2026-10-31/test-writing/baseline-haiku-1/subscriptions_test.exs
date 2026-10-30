ExUnit.start()

defmodule Notify.FakeMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the Subscriptions process, so it reports to the test process
  # through the application environment.
  @impl true
  def deliver(to, subject) do
    send(Application.fetch_env!(:notify, :test_pid), {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Notify.Subscriptions

  setup do
    Application.put_env(:notify, :test_pid, self())
    on_exit(fn -> Application.delete_env(:notify, :test_pid) end)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    server = start_supervised!({Subscriptions, mailer: Notify.FakeMailer, name: name})
    %{server: server}
  end

  describe "start_link/1" do
    test "registers under the module name by default" do
      child = Supervisor.child_spec({Subscriptions, mailer: Notify.FakeMailer}, id: :default_name)
      start_supervised!(child)

      assert Process.whereis(Subscriptions) != nil
      assert :ok = Subscriptions.subscribe("news", self())
      assert Subscriptions.subscribers("news") == [self()]
    end

    test "requires the :mailer option" do
      child = Supervisor.child_spec({Subscriptions, []}, id: :no_mailer)

      capture_log(fn ->
        assert {:error, _} = start_supervised(child)
      end)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns :ok and lists a subscribed pid", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      first = spawn_idle()
      second = spawn_idle()

      Subscriptions.subscribe(server, "news", first)
      Subscriptions.subscribe(server, "news", second)

      assert Subscriptions.subscribers(server, "news") == [second, first]
    end

    test "stores email addresses as strings", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing-here") == []
    end

    test "keeps subscribers of different topics apart", %{server: server} do
      pid = spawn_idle()

      Subscriptions.subscribe(server, "news", pid)

      assert Subscriptions.subscribers(server, "sports") == []
      assert Subscriptions.subscribers(server, "news") == [pid]
    end
  end

  describe "publish/3 to pid subscribers" do
    test "sends {:notification, topic, payload} to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", %{headline: "hello"})

      assert_receive {:notification, "news", %{headline: "hello"}}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      other = spawn_forwarder(self())

      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:forwarded, {:notification, "news", :update}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "sports", :score)
      # Publishes are handled in order, so this match means the "sports"
      # publish has already been processed.
      Subscriptions.publish(server, "news", :headline)

      assert_receive {:notification, "news", :headline}
      refute_received {:notification, "sports", _}
    end

    test "returns :ok when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :payload)
      assert Process.alive?(server)
    end
  end

  describe "publish/3 to email subscribers" do
    test "delivers the email with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "sends email and pid notifications for the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :update)

      assert_receive {:delivered, "reader@example.com", "New on news"}
      assert_receive {:notification, "news", :update}
    end
  end

  describe "when a subscribed pid exits" do
    test "removes the pid from its topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)

      kill_and_wait(pid)

      await(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes the pid from every topic it subscribed to", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      kill_and_wait(pid)

      await(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      gone = spawn_idle()
      Subscriptions.subscribe(server, "news", gone)
      Subscriptions.subscribe(server, "news", self())

      kill_and_wait(gone)

      await(fn -> Subscriptions.subscribers(server, "news") == [self()] end)
    end

    test "publishing after an exit still notifies the remaining subscribers", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      kill_and_wait(pid)
      await(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
    end

    test "leaves email subscribers in place", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "reader@example.com")

      kill_and_wait(pid)

      await(fn -> Subscriptions.subscribers(server, "news") == ["reader@example.com"] end)
    end
  end

  # A process that stays alive until it is killed.
  defp spawn_idle do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  # A process that forwards every message it receives to the test process.
  defp spawn_forwarder(test_pid) do
    spawn(fn -> forward_loop(test_pid) end)
  end

  defp forward_loop(test_pid) do
    receive do
      message ->
        send(test_pid, {:forwarded, message})
        forward_loop(test_pid)
    end
  end

  # Kills the pid and waits until the test process sees it has died.
  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # The server processes the DOWN message on its own schedule, so the test
  # polls until the condition holds.
  defp await(condition, attempts \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met in time")

      true ->
        Process.sleep(10)
        await(condition, attempts - 1)
    end
  end
end
