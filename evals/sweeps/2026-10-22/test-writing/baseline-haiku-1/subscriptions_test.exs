ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  # Mailer that reports each delivery to the test process, which is registered
  # under :notify_test_probe in setup. Global name, so the module is not async.
  defmodule FakeMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      send(:notify_test_probe, {:delivered, to, subject})
      :ok
    end
  end

  defmodule FailingMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(_to, _subject), do: {:error, :smtp_down}
  end

  setup do
    Process.register(self(), :notify_test_probe)
    %{server: start_server(FakeMailer)}
  end

  describe "subscribe/3 and subscribers/2" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", "a@example.com"]
    end

    test "keeps subscribers of different topics apart", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sport", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sport") == ["b@example.com"]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nobody") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :payload)
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :payload)

      assert_receive {:notification, "news", :payload}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "sport", :payload)

      refute_receive {:notification, _, _}, 50
      refute_receive {:delivered, _, _}, 0
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "nobody", :payload) == :ok
      assert Subscriptions.subscribers(server, "nobody") == []
      refute_receive {:notification, _, _}, 50
      refute_receive {:delivered, _, _}, 0
    end

    test "a failing mailer does not stop other notifications" do
      server = start_server(FailingMailer)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :payload)

      assert_receive {:notification, "news", :payload}
      assert Process.alive?(server)
      assert Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    test "removes it after it is killed", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      Process.exit(pid, :kill)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end

    test "removes it after it exits normally", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)

      send(pid, :stop)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes it from every topic it subscribed to and keeps other subscribers", %{
      server: server
    } do
      pid = spawn_idle()
      other = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)
      :ok = Subscriptions.subscribe(server, "news", other)

      Process.exit(pid, :kill)

      wait_until(fn ->
        Subscriptions.subscribers(server, "news") == [other] and
          Subscriptions.subscribers(server, "sport") == []
      end)
    end

    test "publishing after the exit reaches the remaining subscribers", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", self())

      Process.exit(pid, :kill)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :payload)
      assert_receive {:notification, "news", :payload}
    end
  end

  describe "start_link/1" do
    test "fails without the :mailer option" do
      # The server is linked to this process, so trap its exit instead of crashing.
      Process.flag(:trap_exit, true)

      assert {:error, _reason} = Subscriptions.start_link(name: unique_name())
    end
  end

  # The child id is unique so a test can start a second server beside the one from setup.
  defp start_server(mailer) do
    spec = Supervisor.child_spec({Subscriptions, mailer: mailer, name: unique_name()}, id: make_ref())
    start_supervised!(spec)
  end

  defp unique_name do
    :"subscriptions_#{System.unique_integer([:positive])}"
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

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
end
