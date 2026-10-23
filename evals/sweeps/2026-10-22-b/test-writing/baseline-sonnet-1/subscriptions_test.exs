ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      send(Application.fetch_env!(:notify_test, :mail_sink), {:delivered, to, subject})
      :ok
    end
  end

  setup do
    Application.put_env(:notify_test, :mail_sink, self())
    on_exit(fn -> Application.delete_env(:notify_test, :mail_sink) end)

    %{server: start_server(:default)}
  end

  defp start_server(id) do
    name = :"subs_#{id}_#{System.unique_integer([:positive])}"
    spec = Supervisor.child_spec({Subscriptions, mailer: TestMailer, name: name}, id: id)
    start_supervised!(spec)
    name
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "registers under the :name option" do
      name = :"subs_named_#{System.unique_integer([:positive])}"
      {:ok, pid} = Subscriptions.start_link(mailer: TestMailer, name: name)
      assert Process.whereis(name) == pid
      assert Subscriptions.subscribers(name, "t") == []
    end

    test "requires a :mailer" do
      Process.flag(:trap_exit, true)
      name = :"subs_nomailer_#{System.unique_integer([:positive])}"
      assert {:error, _} = Subscriptions.start_link(name: name)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "subscribe returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "lists no subscribers for an unknown topic", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
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

    test "separate servers do not share subscribers", %{server: server} do
      other = start_server(:other)
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(other, "news") == []
    end
  end

  describe "publish/3" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :hello)
    end

    test "sends a notification message to process subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers with a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber, both kinds", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")
      Subscriptions.publish(server, "news", 42)

      assert_receive {:notification, "news", 42}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")
      Subscriptions.publish(server, "news", :x)
      # a call after the cast guarantees the publish has been handled
      Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _, _}, 50
      refute_receive {:delivered, _, _}, 0
    end

    test "publishing to a topic with no subscribers is harmless", %{server: server} do
      Subscriptions.publish(server, "empty", :x)
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "delivers each publish separately and in order", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "a@example.com")
      assert pid in Subscriptions.subscribers(server, "news")

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
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

    test "other subscribers still receive notifications", %{server: server} do
      dead = spawn_idle()
      Subscriptions.subscribe(server, "news", dead)
      Subscriptions.subscribe(server, "news", self())
      Process.exit(dead, :kill)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after)
      assert_receive {:notification, "news", :after}
    end

    test "an abnormal exit does not crash the server", %{server: server} do
      server_pid = Process.whereis(server)
      pid = spawn(fn -> exit(:boom) end)
      Subscriptions.subscribe(server, "news", pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Process.whereis(server) == server_pid
    end

    test "subscribing an already-dead pid gets it removed", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      Subscriptions.subscribe(server, "news", pid)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "email subscribers are unaffected", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end
  end
end
