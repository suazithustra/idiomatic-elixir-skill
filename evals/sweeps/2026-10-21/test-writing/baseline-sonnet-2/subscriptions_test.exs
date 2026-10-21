ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    # The mailer is a module, so it finds the test process through the application env.
    @impl true
    def deliver(to, subject) do
      send(Application.fetch_env!(:notify_test, :mailer_test_pid), {:delivered, to, subject})
      :ok
    end
  end

  setup do
    Application.put_env(:notify_test, :mailer_test_pid, self())
    on_exit(fn -> Application.delete_env(:notify_test, :mailer_test_pid) end)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: name}
  end

  # Polls until `fun` returns a truthy value, since monitor DOWN messages arrive asynchronously.
  defp eventually(fun, attempts \\ 50) do
    cond do
      result = fun.() ->
        result

      attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      true ->
        flunk("condition not met in time")
    end
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _}} =
               Subscriptions.start_link(name: :subscriptions_no_mailer)
    end

    test "registers under Notify.Subscriptions by default" do
      Process.flag(:trap_exit, true)
      pid = start_supervised!({Subscriptions, mailer: TestMailer}, id: :default_name)

      assert Process.whereis(Notify.Subscriptions) == pid
      assert Subscriptions.subscribe("t", "a@example.com") == :ok
      assert Subscriptions.subscribers("t") == ["a@example.com"]
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "subscribes a pid and an email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      for email <- ["1@example.com", "2@example.com", "3@example.com"] do
        Subscriptions.subscribe(server, "news", email)
      end

      assert Subscriptions.subscribers(server, "news") ==
               ["3@example.com", "2@example.com", "1@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "a", "a@example.com")
      Subscriptions.subscribe(server, "b", "b@example.com")

      assert Subscriptions.subscribers(server, "a") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "b") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok immediately, even for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.publish(server, "nobody", :payload) == :ok
      assert Subscriptions.subscribers(server, "nobody") == []
      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "sends a process subscriber {:notification, topic, payload}", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
      refute_received {:notification, _, _}
    end

    test "notifies both kinds of subscriber on the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", 42)

      assert_receive {:notification, "news", 42}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "a", self())
      Subscriptions.subscribe(server, "b", "b@example.com")
      Subscriptions.publish(server, "a", :hello)

      assert_receive {:notification, "a", :hello}
      # publish is a cast; a following call guarantees it has been handled.
      Subscriptions.subscribers(server, "a")
      refute_received {:delivered, _, _}
    end

    test "notifies once per message published", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
      Subscriptions.subscribers(server, "news")
      refute_received {:notification, _, _}
    end

    test "delivers to every subscriber, including other processes", %{server: server} do
      test_pid = self()

      other =
        spawn_link(fn ->
          receive do
            msg -> send(test_pid, {:other_got, msg})
          end
        end)

      Subscriptions.subscribe(server, "news", other)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", :x)

      assert_receive {:notification, "news", :x}
      assert_receive {:other_got, {:notification, "news", :x}}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the subscribers", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed after a crash too", %{server: server} do
      pid = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      Subscriptions.subscribe(server, "news", pid)

      send(pid, :crash)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it joined", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      send(pid, :stop)

      eventually(fn ->
        Subscriptions.subscribers(server, "a") == [] and
          Subscriptions.subscribers(server, "b") == []
      end)
    end

    test "other subscribers stay subscribed and still get notified", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      send(pid, :stop)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [self(), "a@example.com"] end)

      Subscriptions.publish(server, "news", :after_exit)
      assert_receive {:notification, "news", :after_exit}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "publishing after the exit does not fail the server", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      send(pid, :stop)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)

      server_pid = Process.whereis(server)
      assert Subscriptions.publish(server, "news", :late) == :ok
      assert Subscriptions.subscribers(server, "news") == []
      assert Process.whereis(server) == server_pid
    end

    test "an already-dead pid is removed shortly after subscribing", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Subscriptions.subscribe(server, "news", pid) == :ok
      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end
end
