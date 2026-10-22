ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @behaviour Notify.Mailer

  # Reports every delivery to the process registered as :notify_test_mailer.
  @impl true
  def deliver(to, subject) do
    send(:notify_test_mailer, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup do
    Process.register(self(), :notify_test_mailer)
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    {:ok, server: name, server_pid: pid}
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Publishing is a cast; a following call is handled after it, so this waits for it.
  defp sync(server), do: Subscriptions.subscribers(server, "__sync__")

  describe "start_link/1" do
    test "raises when the mailer option is missing" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _}} =
               Subscriptions.start_link(name: :no_mailer_subscriptions)
    end

    test "registers under the given name", %{server: name, server_pid: pid} do
      assert Process.whereis(name) == pid
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "an unknown topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "subscribe returns :ok", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
    end

    test "lists pids and emails, most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", self(), "a@example.com"]
    end

    test "topics are independent", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end

    test "the same subscriber can be listed more than once", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", "a@example.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok immediately", %{server: server} do
      assert Subscriptions.publish(server, "news", :payload) == :ok
    end

    test "sends a notification message to pid subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies pids and emails together", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")
      Subscriptions.publish(server, "news", "hello")
      sync(server)

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "publishing to a topic with no subscribers does nothing", %{server: server, server_pid: pid} do
      Subscriptions.publish(server, "empty", :x)
      sync(server)

      refute_received _
      assert Process.alive?(pid)
    end

    test "each publish produces its own notification, in order", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end

    test "a subscribed pid gets one message per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", :dup)
      sync(server)

      assert_received {:notification, "news", :dup}
      assert_received {:notification, "news", :dup}
      refute_received {:notification, _, _}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      assert Subscriptions.subscribers(server, "news") == [subscriber]

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _}

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic", %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)

      Process.exit(subscriber, :kill)

      assert eventually(fn ->
               Subscriptions.subscribers(server, "news") == [] and
                 Subscriptions.subscribers(server, "sports") == []
             end)
    end

    test "other subscribers are kept", %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", self())

      Process.exit(subscriber, :kill)

      assert eventually(fn ->
               Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
             end)
    end

    test "publishing afterwards does not notify the dead process and the server survives",
         %{server: server, server_pid: pid} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", self())
      Process.exit(subscriber, :kill)
      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after)

      assert_receive {:notification, "news", :after}
      assert Process.alive?(pid)
    end

    test "exits with a non-normal reason are handled too", %{server: server, server_pid: pid} do
      subscriber =
        spawn(fn ->
          receive do
            :crash -> exit(:boom)
          end
        end)

      Subscriptions.subscribe(server, "news", subscriber)
      send(subscriber, :crash)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Process.alive?(pid)
    end

    test "a process already dead at subscribe time is removed", %{server: server} do
      subscriber = spawn_subscriber()
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _}

      Subscriptions.subscribe(server, "news", subscriber)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "email subscribers are unaffected", %{server: server} do
      subscriber = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", subscriber)
      Process.exit(subscriber, :kill)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)

      Subscriptions.publish(server, "news", :x)
      assert_receive {:delivered, "a@example.com", "New on news"}
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
