ExUnit.start()

defmodule Notify.Subscriptions.TestMailer do
  @behaviour Notify.Mailer

  @inbox :notify_subscriptions_test_inbox

  def inbox, do: @inbox

  @impl true
  def deliver(to, subject) do
    send(@inbox, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup context do
    Process.register(self(), Notify.Subscriptions.TestMailer.inbox())

    server =
      start_supervised!(
        {Subscriptions,
         [mailer: Notify.Subscriptions.TestMailer, name: :"subs_#{context.test}"]}
      )

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
    result = fun.()

    cond do
      result -> result
      attempts == 0 -> flunk("condition not met in time")
      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _}} =
               Subscriptions.start_link(name: :subs_without_mailer)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "a topic without subscribers is empty", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "lists pids and emails, most recent first", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", pid, "a@example.com"]
    end

    test "topics are independent", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end

    test "works through the registered name" do
      name = :subs_named_lookup
      start_supervised!(
        {Subscriptions, [mailer: Notify.Subscriptions.TestMailer, name: name]},
        id: :named_lookup
      )

      :ok = Subscriptions.subscribe(name, "news", "a@example.com")
      assert Subscriptions.subscribers(name, "news") == ["a@example.com"]
    end

    test "defaults to the Notify.Subscriptions name" do
      start_supervised!(
        {Subscriptions, [mailer: Notify.Subscriptions.TestMailer]},
        id: :default_named
      )

      assert :ok = Subscriptions.subscribe("news", "a@example.com")
      assert Subscriptions.subscribers("news") == ["a@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to pid subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers with a subject naming the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not send the payload to email subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.publish(server, "news", :secret)

      assert_receive {:delivered, "a@example.com", subject}
      refute subject =~ "secret"
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.publish(server, "news", 42)

      assert_receive {:notification, "news", 42}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")
      :ok = Subscriptions.publish(server, "news", 1)

      assert_receive {:delivered, "a@example.com", _}
      assert_receive {:delivered, "b@example.com", _}
    end

    test "only reaches subscribers of the published topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")
      :ok = Subscriptions.publish(server, "news", 1)

      # a call after the cast guarantees the publish has been handled
      _ = Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _, _}, 50
      refute_receive {:delivered, _, _}, 50
    end

    test "publishing to a topic without subscribers is a no-op", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", 1)
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "returns before subscribers are notified", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :sys.suspend(server)
      assert :ok = Subscriptions.publish(server, "news", 1)
      refute_received {:notification, _, _}

      :sys.resume(server)
      assert_receive {:notification, "news", 1}
    end

    test "messages arrive in publish order", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      for n <- 1..3, do: Subscriptions.publish(server, "news", n)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
      assert_receive {:notification, "news", 3}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      kill(pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end

    test "it is removed from every topic", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sports", pid)

      kill(pid)

      eventually(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "a normal exit also removes it", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "other subscribers are kept and still notified", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", self())
      kill(pid)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      :ok = Subscriptions.publish(server, "news", :after_exit)
      assert_receive {:notification, "news", :after_exit}
    end

    test "publishing after the exit does not crash the server", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      kill(pid)
      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)

      :ok = Subscriptions.publish(server, "news", 1)
      assert Process.alive?(server)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "a pid subscribed twice is fully removed", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", pid)

      kill(pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "an exit leaves email subscribers of other topics alone", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "other", pid)

      kill(pid)
      eventually(fn -> Subscriptions.subscribers(server, "other") == [] end)

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
