ExUnit.start()

defmodule Notify.SubscriptionsTest.FakeMailer do
  @behaviour Notify.Mailer

  @sink :notify_subscriptions_test_mailer_sink

  def sink, do: @sink

  @impl true
  def deliver(to, subject) do
    send(@sink, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.FakeMailer

  setup do
    Process.register(self(), FakeMailer.sink())
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: FakeMailer, name: name})
    %{server: name}
  end

  # Publish is a cast; a later call is handled after it, so this waits for it.
  defp sync(server), do: Subscriptions.subscribers(server, "__sync__")

  defp spawn_subscriber do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp wait_until_down(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _}} =
               Subscriptions.start_link(name: :no_mailer_server)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "an unknown topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nobody") == []
    end

    test "subscribing a pid returns :ok and lists it", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "subscribing an email lists it", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "lists subscribers most recent first", %{server: server} do
      pid = self()
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

    test "uses the default name when none is given" do
      # The setup server has a custom name; start one under the default name.
      start_supervised!({Subscriptions, mailer: FakeMailer}, id: :default_named)

      assert :ok = Subscriptions.subscribe("topic", "a@example.com")
      assert Subscriptions.subscribers("topic") == ["a@example.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok even with no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :payload)
      assert sync(server) == []
      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "sends a process subscriber a notification message", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "a@example.com", "New on news"}
      refute_received {:notification, _, _}
    end

    test "notifies process and email subscribers together", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      other = spawn_subscriber_forwarding_to(self())
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:forwarded, ^other, {:notification, "news", :hello}}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")
      Subscriptions.publish(server, "news", :hello)
      sync(server)

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "delivers each publish separately and in order", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end

    test "a subscriber added twice is notified twice", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", _}
      assert_receive {:delivered, "a@example.com", _}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from its topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      wait_until_down(pid)
      # The server's own :DOWN message may still be in flight; poll until handled.
      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it was subscribed to", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      wait_until_down(pid)

      assert eventually(fn ->
               Subscriptions.subscribers(server, "news") == [] and
                 Subscriptions.subscribers(server, "sports") == []
             end)
    end

    test "other subscribers stay subscribed", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      wait_until_down(pid)

      assert eventually(fn ->
               Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
             end)
    end

    test "a pid subscribed twice is fully removed", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", pid)

      wait_until_down(pid)

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "publishing afterwards does not message the dead process and the server survives",
         %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      wait_until_down(pid)
      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      server_pid = Process.whereis(server)
      Subscriptions.publish(server, "news", :after)

      assert_receive {:notification, "news", :after}
      assert Process.whereis(server) == server_pid
    end

    test "a normal exit also removes the subscriber", %{server: server} do
      parent = self()

      pid =
        spawn(fn ->
          receive do
            :stop -> send(parent, :stopped)
          end
        end)

      Subscriptions.subscribe(server, "news", pid)
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "subscribing an already dead pid is removed right away", %{server: server} do
      pid = spawn_subscriber()
      wait_until_down(pid)

      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  defp spawn_subscriber_forwarding_to(test_pid) do
    spawn(fn -> forward_loop(test_pid) end)
  end

  defp forward_loop(test_pid) do
    receive do
      msg ->
        send(test_pid, {:forwarded, self(), msg})
        forward_loop(test_pid)
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end
end
