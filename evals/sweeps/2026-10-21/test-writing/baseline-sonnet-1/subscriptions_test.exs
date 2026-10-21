ExUnit.start()

defmodule Notify.TestMailer do
  @behaviour Notify.Mailer

  # The server calls the mailer from its own process, so the test pid is
  # passed through the application environment.
  @impl true
  def deliver(to, subject) do
    send(Application.fetch_env!(:notify_test, :mailer_test_pid), {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    Application.put_env(:notify_test, :mailer_test_pid, self())
    on_exit(fn -> Application.delete_env(:notify_test, :mailer_test_pid) end)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name}, id: name)
    %{server: name}
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      true ->
        :ok

      _ when attempts > 1 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      other ->
        flunk("condition not met, last result: #{inspect(other)}")
    end
  end

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _stacktrace}} =
               Subscriptions.start_link(name: :no_mailer_subscriptions)
    end

    test "registers under the given name", %{server: server} do
      assert is_pid(Process.whereis(server))
    end
  end

  describe "subscribe/3" do
    test "returns :ok for a pid", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "returns :ok for an email address", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
    end

    test "uses the default name when none is given" do
      # The default server is not started by setup, so start it here.
      start_supervised!({Subscriptions, mailer: Notify.TestMailer}, id: :default_server)

      assert :ok = Subscriptions.subscribe("default-topic", self())
      assert Subscriptions.subscribers("default-topic") == [self()]
    end
  end

  describe "subscribers/2" do
    test "is empty for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "lists pids and emails, most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", self(), "a@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok even with no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :hello)
    end

    test "sends a notification message to pid subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers with a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", 42)

      assert_receive {:notification, "news", 42}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "b@example.com")
      Subscriptions.publish(server, "news", :x)

      # Calls are handled after earlier casts, so the publish is done by now.
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "notifies every subscriber, each once", %{server: server} do
      other = spawn_idle()
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)
      Subscriptions.publish(server, "news", :once)

      assert_receive {:notification, "news", :once}
      refute_receive {:notification, "news", :once}, 50
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it joined", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      Process.exit(pid, :kill)

      eventually(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "other subscribers stay subscribed", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [self(), "a@example.com"] end)
    end

    test "publishing afterwards does not notify the dead process and the server survives",
         %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Process.exit(pid, :kill)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after)

      assert_receive {:notification, "news", :after}
      assert Process.alive?(Process.whereis(server))
    end

    test "a pid that subscribed twice is fully removed", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "email subscribers are unaffected by process exits", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "other", pid)
      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "other") == [] end)
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end
  end
end
