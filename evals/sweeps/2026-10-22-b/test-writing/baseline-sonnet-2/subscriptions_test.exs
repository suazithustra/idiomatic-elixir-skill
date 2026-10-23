ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule FakeMailer do
    @behaviour Notify.Mailer

    # The server calls the mailer from its own process, so the test registers
    # itself under this name to receive the deliveries.
    @impl true
    def deliver(to, subject) do
      send(:fake_mailer_inbox, {:delivered, to, subject})
      :ok
    end
  end

  setup do
    Process.register(self(), :fake_mailer_inbox)
    server = start_supervised!({Subscriptions, mailer: FakeMailer, name: nil} |> child_spec())
    {:ok, server: server}
  end

  defp child_spec({_mod, opts}) do
    opts = Keyword.delete(opts, :name)

    %{
      id: make_ref(),
      start: {GenServer, :start_link, [Subscriptions, opts]}
    }
  end

  # publish/3 is a cast; a following call is handled after it, so this waits for it.
  defp flush(server), do: Subscriptions.subscribers(server, "__flush__")

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  describe "start_link/1" do
    test "registers under the given name" do
      name = :"subs_#{System.unique_integer([:positive])}"
      {:ok, pid} = Subscriptions.start_link(mailer: FakeMailer, name: name)

      assert Process.whereis(name) == pid
      assert Subscriptions.subscribers(name, "t") == []
    end

    test "requires a mailer" do
      Process.flag(:trap_exit, true)

      assert {:error, _} = Subscriptions.start_link(name: :subs_no_mailer)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "an unknown topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "subscribing returns :ok and lists the subscriber", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first, mixing pids and emails", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", pid, "a@example.com"]
    end

    test "topics are independent", %{server: server} do
      Subscriptions.subscribe(server, "a", "a@example.com")
      Subscriptions.subscribe(server, "b", "b@example.com")

      assert Subscriptions.subscribers(server, "a") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "b") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a process subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
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

      refute_receive {:notification, _, _}, 50
      refute_receive {:delivered, _, _}, 50
    end

    test "publishing to a topic without subscribers is a no-op", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", 1)
      assert flush(server) == []
    end

    test "each publish produces its own notification", %{server: server} do
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

      stop_and_wait(pid)
      # :sys.get_state/1 returns only after the server has handled earlier messages.
      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end

    test "it is removed from every topic it subscribed to", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      stop_and_wait(pid)

      wait_until(fn ->
        Subscriptions.subscribers(server, "a") == [] and
          Subscriptions.subscribers(server, "b") == []
      end)
    end

    test "other subscribers are kept and still notified", %{server: server} do
      dying = spawn_idle()
      Subscriptions.subscribe(server, "news", dying)
      Subscriptions.subscribe(server, "news", self())

      stop_and_wait(dying)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after_exit)
      assert_receive {:notification, "news", :after_exit}
    end

    test "a crashed process is removed and the server survives", %{server: server} do
      pid = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :crash)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Process.alive?(server)
    end

    test "publishing after the exit does not fail", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      stop_and_wait(pid)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)

      assert :ok = Subscriptions.publish(server, "news", 1)
      assert flush(server) == []
      assert Process.alive?(server)
    end

    test "subscribing an already dead process removes it right away", %{server: server} do
      pid = spawn_idle()
      stop_and_wait(pid)

      Subscriptions.subscribe(server, "news", pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
