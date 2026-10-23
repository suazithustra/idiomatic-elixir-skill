ExUnit.start()

defmodule Notify.Subscriptions.TestMailer do
  @behaviour Notify.Mailer

  # The mailer is a plain module, so the test process is found through the application env.
  @impl true
  def deliver(to, subject) do
    case Application.get_env(:notify_test, :mail_inbox) do
      nil -> :ok
      pid -> send(pid, {:mail, to, subject})
    end

    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.Subscriptions.TestMailer

  setup do
    Application.put_env(:notify_test, :mail_inbox, self())
    on_exit(fn -> Application.delete_env(:notify_test, :mail_inbox) end)

    server = start_supervised!({Subscriptions, mailer: TestMailer, name: :subscriptions_under_test})
    %{server: server}
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Publishing is a cast, so a following call is processed only after the publish.
  defp sync(server), do: Subscriptions.subscribers(server, "__sync__")

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "registers under the module name by default" do
      stop_supervised!(Subscriptions)
      {:ok, pid} = Subscriptions.start_link(mailer: TestMailer)
      assert Process.whereis(Notify.Subscriptions) == pid
      assert Subscriptions.subscribers("t") == []
      GenServer.stop(pid)
    end

    test "requires a :mailer" do
      Process.flag(:trap_exit, true)
      assert {:error, {%KeyError{key: :mailer}, _}} = Subscriptions.start_link(name: :no_mailer)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
    end

    test "an unknown topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "lists subscribers most recent first", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", pid, "a@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end

    test "the same subscriber can join several topics", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["a@example.com"]
    end

    test "works through the registered name" do
      assert :ok = Subscriptions.subscribe(:subscriptions_under_test, "news", "a@example.com")
      assert Subscriptions.subscribers(:subscriptions_under_test, "news") == ["a@example.com"]
    end
  end

  describe "publish/3 to process subscribers" do
    test "sends the notification to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "notifies every subscribed pid", %{server: server} do
      parent = self()

      pids =
        for n <- 1..3 do
          pid =
            spawn_link(fn ->
              receive do
                msg -> send(parent, {:got, n, msg})
              end
            end)

          Subscriptions.subscribe(server, "news", pid)
          pid
        end

      Subscriptions.publish(server, "news", :hello)

      for n <- 1..3, do: assert_receive({:got, ^n, {:notification, "news", :hello}})
      assert length(pids) == 3
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())

      Subscriptions.publish(server, "news", :hello)
      sync(server)

      refute_received {:notification, _, _}
    end

    test "publishing to a topic with no subscribers is a no-op", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert sync(server) == []
      refute_received _
    end

    test "each publish is delivered in order", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails the address with a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:mail, "a@example.com", "New on news"}
    end

    test "mails every address once per publish", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", :x)

      assert_receive {:mail, "a@example.com", "New on news"}
      assert_receive {:mail, "b@example.com", "New on news"}
      sync(server)
      refute_received {:mail, _, _}
    end

    test "does not mail addresses subscribed to other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", "a@example.com")

      Subscriptions.publish(server, "news", :x)
      sync(server)

      refute_received {:mail, _, _}
    end

    test "pids and emails on the same topic are each notified their own way", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :both)

      assert_receive {:notification, "news", :both}
      assert_receive {:mail, "a@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the subscribers", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it joined", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      Process.exit(pid, :kill)

      eventually(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "other subscribers are kept", %{server: server} do
      pid = spawn_subscriber()
      other = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", other)

      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [other, "a@example.com"] end)
    end

    test "the server stays alive and keeps publishing", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      Process.exit(pid, :kill)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      assert Process.alive?(server)
      Subscriptions.publish(server, "news", :after_exit)
      assert_receive {:notification, "news", :after_exit}
    end

    test "an abnormal exit reason is handled the same way", %{server: server} do
      pid = spawn(fn -> exit(:boom) end)
      Subscriptions.subscribe(server, "news", pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Process.alive?(server)
    end

    test "subscribing an already dead pid is cleaned up", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      Subscriptions.subscribe(server, "news", pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "email subscribers are unaffected by process exits", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)
      eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)

      Subscriptions.publish(server, "news", :x)
      assert_receive {:mail, "a@example.com", "New on news"}
    end
  end
end
