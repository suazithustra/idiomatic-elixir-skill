ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @behaviour Notify.Mailer

  @sink :notify_subscriptions_test_mail_sink

  def sink, do: @sink

  @impl true
  def deliver(to, subject) do
    send(@sink, {:delivered, to, subject})
    if to == "bounce@example.com", do: {:error, :bounced}, else: :ok
  end
end

defmodule Notify.SubscriptionsTest do
  # The mailer reports to a globally registered name, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  setup do
    Process.register(self(), Mailer.sink())
    server = start_supervised!({Subscriptions, [mailer: Mailer, name: :subscriptions_under_test]}, id: :subs)
    %{server: server}
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "registers under the :name option" do
      assert is_pid(Process.whereis(:subscriptions_under_test))
    end

    test "defaults the name to Notify.Subscriptions" do
      start_supervised!({Subscriptions, [mailer: Mailer]}, id: :default_named)
      assert is_pid(Process.whereis(Notify.Subscriptions))
      assert Subscriptions.subscribers("t") == []
    end

    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)
      assert {:error, {%KeyError{key: :mailer}, _}} = Subscriptions.start_link(name: :no_mailer)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "subscribes a pid and an email address", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")

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

    test "works through the registered name" do
      assert :ok = Subscriptions.subscribe(:subscriptions_under_test, "news", "a@example.com")
      assert Subscriptions.subscribers(:subscriptions_under_test, "news") == ["a@example.com"]
    end

    test "the same subscriber subscribed twice is listed twice", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", "a@example.com"]
    end
  end

  describe "publish/3 to process subscribers" do
    test "sends the notification message to the pid", %{server: server} do
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
                {:notification, _, _} = msg -> send(parent, {:got, n, msg})
              end
            end)

          Subscriptions.subscribe(server, "news", pid)
          pid
        end

      Subscriptions.publish(server, "news", :hello)

      for n <- 1..3, do: assert_receive({:got, ^n, {:notification, "news", :hello}})
      assert length(pids) == 3
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "other", self())

      Subscriptions.publish(server, "news", :hello)
      # Calls are handled after the earlier publish cast, so it has been processed by now.
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _, _}
    end

    test "publishing to a topic with no subscribers is fine", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :hello)
      assert Subscriptions.subscribers(server, "nobody") == []
    end

    test "delivers a notification once per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", 1)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 1}
      refute_receive {:notification, _, _}, 50
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails the address with a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "mails every address on the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", :x)

      assert_receive {:delivered, "a@example.com", _}
      assert_receive {:delivered, "b@example.com", _}
    end

    test "does not mail addresses subscribed to other topics", %{server: server} do
      Subscriptions.subscribe(server, "other", "a@example.com")

      Subscriptions.publish(server, "news", :x)
      Subscriptions.subscribers(server, "news")

      refute_received {:delivered, _, _}
    end

    test "handles a mix of pids and addresses", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :x)

      assert_receive {:notification, "news", :x}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "a failed delivery does not stop the server or the other subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", "ok@example.com")
      Subscriptions.subscribe(server, "news", "bounce@example.com")
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :x)

      assert_receive {:delivered, "bounce@example.com", _}
      assert_receive {:delivered, "ok@example.com", _}
      assert_receive {:notification, "news", :x}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      send(pid, :stop)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it was subscribed to", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      Process.exit(pid, :kill)

      eventually(fn ->
        Subscriptions.subscribers(server, "a") == [] and Subscriptions.subscribers(server, "b") == []
      end)
    end

    test "it is removed whatever the exit reason", %{server: server} do
      crashing = spawn(fn -> receive do :go -> exit(:boom) end end)
      Subscriptions.subscribe(server, "news", crashing)

      send(crashing, :go)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "other subscribers are kept", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [self(), "a@example.com"] end)
    end

    test "publishing afterwards notifies only the remaining subscribers", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      Process.exit(pid, :kill)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after)

      assert_receive {:notification, "news", :after}
      assert Process.alive?(server)
    end

    test "the server survives the exit", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)

      assert Process.alive?(server)
    end

    test "subscribing a process that is already dead is removed right away", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      Subscriptions.subscribe(server, "news", pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end
end
