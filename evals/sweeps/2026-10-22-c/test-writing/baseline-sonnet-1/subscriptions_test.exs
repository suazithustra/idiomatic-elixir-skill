ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      send(Application.fetch_env!(:notify_test, :mail_sink), {:mail, to, subject})
      :ok
    end
  end

  setup do
    Application.put_env(:notify_test, :mail_sink, self())
    on_exit(fn -> Application.delete_env(:notify_test, :mail_sink) end)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: name}
  end

  # Waits until `fun` returns a truthy value; monitor DOWN handling is asynchronous.
  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  defp spawn_subscriber do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  describe "start_link/1" do
    test "requires a :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, _} = Subscriptions.start_link(name: :no_mailer_subscriptions)
    end

    test "registers under Notify.Subscriptions by default" do
      pid = start_supervised!({Subscriptions, mailer: TestMailer}, id: :default_named)

      assert Process.whereis(Subscriptions) == pid
      assert :ok = Subscriptions.subscribe("t", "a@example.com")
      assert Subscriptions.subscribers("t") == ["a@example.com"]
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "subscribes pids and emails", %{server: server} do
      pid = spawn_subscriber()

      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", pid]
    end

    test "lists the most recent subscriber first", %{server: server} do
      for email <- ["1@x.com", "2@x.com", "3@x.com"] do
        Subscriptions.subscribe(server, "news", email)
      end

      assert Subscriptions.subscribers(server, "news") == ["3@x.com", "2@x.com", "1@x.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "a", "a@x.com")
      Subscriptions.subscribe(server, "b", "b@x.com")

      assert Subscriptions.subscribers(server, "a") == ["a@x.com"]
      assert Subscriptions.subscribers(server, "b") == ["b@x.com"]
    end

    test "does not deduplicate repeated subscriptions", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@x.com")
      Subscriptions.subscribe(server, "news", "a@x.com")

      assert Subscriptions.subscribers(server, "news") == ["a@x.com", "a@x.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok immediately", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :payload)
    end

    test "sends a notification message to pid subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "delivers an email to email subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:mail, "a@example.com", "New on news"}
    end

    test "notifies both kinds of subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:mail, "a@example.com", "New on news"}
      assert_receive {:mail, "b@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "other", self())
      Subscriptions.subscribe(server, "other", "o@example.com")

      Subscriptions.publish(server, "news", "hello")
      # Calls are handled after the earlier cast, so the publish has been processed.
      Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _, _}, 50
      refute_receive {:mail, _, _}, 50
    end

    test "notifies each repeated subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", 1)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 1}
    end

    test "publishing to a topic without subscribers does nothing", %{server: server} do
      Subscriptions.publish(server, "nobody", :x)

      assert Subscriptions.subscribers(server, "nobody") == []
      refute_receive _, 20
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "a@example.com")

      Process.exit(pid, :kill)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end

    test "it is removed from every topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      Process.exit(pid, :kill)

      assert eventually(fn ->
               Subscriptions.subscribers(server, "a") == [] and
                 Subscriptions.subscribers(server, "b") == []
             end)
    end

    test "it is removed after a normal exit", %{server: server} do
      pid = spawn(fn -> receive do: (:stop -> :ok) end)
      Subscriptions.subscribe(server, "news", pid)

      send(pid, :stop)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "publishing afterwards does not message the dead process and the server survives",
         %{server: server} do
      dead = spawn_subscriber()
      Subscriptions.subscribe(server, "news", dead)
      Subscriptions.subscribe(server, "news", self())
      server_pid = Process.whereis(server)

      Process.exit(dead, :kill)
      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after_exit)

      assert_receive {:notification, "news", :after_exit}
      assert Process.whereis(server) == server_pid
    end

    test "other subscribers are left untouched", %{server: server} do
      keep = spawn_subscriber()
      drop = spawn_subscriber()
      Subscriptions.subscribe(server, "news", keep)
      Subscriptions.subscribe(server, "news", drop)

      Process.exit(drop, :kill)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [keep] end)
    end

    test "email subscribers are not affected by process exits", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)
      assert eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)

      Subscriptions.publish(server, "news", :x)
      assert_receive {:mail, "a@example.com", "New on news"}
    end
  end
end
