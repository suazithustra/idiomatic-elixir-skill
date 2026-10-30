ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    # Runs inside the Subscriptions server, so it reports to the test process
    # through a registered name.
    @impl true
    def deliver(to, subject) do
      send(:subscriptions_test_process, {:delivered, to, subject})
      :ok
    end
  end

  setup do
    Process.register(self(), :subscriptions_test_process)
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: nil} |> child_spec())
    %{server: server}
  end

  defp child_spec({_mod, opts}) do
    %{id: Subscriptions, start: {Subscriptions, :start_link, [opts]}}
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = Subscriptions.start_link(name: nil)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "subscribes pids and emails", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "one@example.com")
      Subscriptions.subscribe(server, "news", "two@example.com")
      Subscriptions.subscribe(server, "news", "three@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["three@example.com", "two@example.com", "one@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "a", "a@example.com")
      Subscriptions.subscribe(server, "b", "b@example.com")

      assert Subscriptions.subscribers(server, "a") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "b") == ["b@example.com"]
    end

    test "the same subscriber can be on several topics", %{server: server} do
      Subscriptions.subscribe(server, "a", "x@example.com")
      Subscriptions.subscribe(server, "b", "x@example.com")

      assert Subscriptions.subscribers(server, "a") == ["x@example.com"]
      assert Subscriptions.subscribers(server, "b") == ["x@example.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok even with no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :hello)
      # The server is still alive and responsive afterwards.
      assert Subscriptions.subscribers(server, "nobody") == []
    end

    test "sends a notification message to process subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies both kinds of subscriber on the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", "payload")

      assert_receive {:notification, "news", "payload"}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber once", %{server: server} do
      other = spawn_subscriber_forwarding(self())
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)

      Subscriptions.publish(server, "news", 1)

      assert_receive {:notification, "news", 1}
      assert_receive {:forwarded, ^other, {:notification, "news", 1}}
      refute_receive {:notification, "news", 1}
      refute_receive {:forwarded, ^other, _}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "other", self())
      Subscriptions.subscribe(server, "other", "a@example.com")

      Subscriptions.publish(server, "news", :x)
      # Barrier: the cast is processed before this call is answered.
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "notifies a subscriber once per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :twice)

      assert_receive {:notification, "news", :twice}
      assert_receive {:notification, "news", :twice}
      refute_receive {:notification, _, _}, 50
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "a@example.com")
      assert pid in Subscriptions.subscribers(server, "news")

      stop(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end

    test "it is removed from every topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      stop(pid)

      wait_until(fn ->
        Subscriptions.subscribers(server, "a") == [] and
          Subscriptions.subscribers(server, "b") == []
      end)
    end

    test "it is removed when the process crashes", %{server: server} do
      pid = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :crash)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "other subscribers still get published messages", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      stop(pid)
      wait_until(fn -> pid not in Subscriptions.subscribers(server, "news") end)

      Subscriptions.publish(server, "news", :after_exit)

      assert_receive {:notification, "news", :after_exit}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "the server keeps running", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      stop(pid)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)

      assert Process.alive?(server)
    end

    test "email subscribers are unaffected by process exits", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)

      stop(pid)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end
  end

  # Stops a spawned subscriber and waits until it is dead.
  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # A subscriber that forwards whatever it receives to `target`.
  defp spawn_subscriber_forwarding(target) do
    spawn_link(fn -> forward_loop(target) end)
  end

  defp forward_loop(target) do
    receive do
      msg ->
        send(target, {:forwarded, self(), msg})
        forward_loop(target)
    end
  end
end
