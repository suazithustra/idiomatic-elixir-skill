ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest.FailingMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    test_pid = :persistent_term.get({Notify.SubscriptionsTest.Mailer, :test_pid})
    send(test_pid, {:attempted, to, subject})
    {:error, :smtp_down}
  end
end

defmodule Notify.SubscriptionsTest do
  # The mailer finds the test process through :persistent_term, so tests run serially.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.{FailingMailer, Mailer}

  setup do
    :persistent_term.put({Mailer, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({Mailer, :test_pid}) end)
    %{server: start_server(Mailer)}
  end

  defp start_server(mailer) do
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: mailer, name: name}, id: name)
    name
  end

  # `publish/3` is a cast, so a following call guarantees it has been handled.
  defp flush(server), do: Subscriptions.subscribers(server, "__flush__")

  defp spawn_subscriber do
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
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "registers under the given name", %{server: server} do
      assert is_pid(Process.whereis(server))
    end

    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _}} =
               Subscriptions.start_link(name: :no_mailer_subscriptions)
    end
  end

  describe "subscribe/3" do
    test "returns :ok for a pid and for an email address", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
    end
  end

  describe "subscribers/2" do
    test "is empty for an unknown topic", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
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
    test "sends a notification message to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert :ok = Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")

      Subscriptions.publish(server, "news", "hello")
      flush(server)

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", "hello")
      assert flush(server) == []
    end

    test "sends one message per publish", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
      refute_receive {:notification, _, _}, 50
    end

    test "keeps running when the mailer returns an error" do
      server = start_server(FailingMailer)
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:attempted, "a@example.com", "New on news"}
      assert_receive {:notification, "news", "hello"}
      assert Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      send(pid, :stop)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed on an abnormal exit too", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      send(pid, :stop)

      wait_until(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "other subscribers stay subscribed, in order", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      send(pid, :stop)

      wait_until(fn -> pid not in Subscriptions.subscribers(server, "news") end)
      assert Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
    end

    test "publishing afterwards still reaches the remaining subscribers", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      send(pid, :stop)
      wait_until(fn -> pid not in Subscriptions.subscribers(server, "news") end)

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "the server keeps running", %{server: server} do
      server_pid = Process.whereis(server)
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)

      assert Process.whereis(server) == server_pid
      assert Process.alive?(server_pid)
    end
  end
end
