ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @behaviour Notify.Mailer

  # The mailer is a module, so it reports to whichever process registered this name.
  @sink __MODULE__.Sink

  def sink, do: @sink

  @impl true
  def deliver(to, subject) do
    send(@sink, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  # Not async: the test mailer reports to a globally registered name.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  setup do
    Process.register(self(), Mailer.sink())
    name = :"subscriptions_#{System.unique_integer([:positive])}"

    server =
      start_supervised!(%{
        id: Subscriptions,
        start: {Subscriptions, :start_link, [[mailer: Mailer, name: name]]}
      })

    %{server: server}
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # `publish/3` is a cast; a following call from the same process is handled after it.
  defp flush(server, topic), do: Subscriptions.subscribers(server, topic)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  describe "start_link/1" do
    test "registers under the given name" do
      {:ok, pid} = Subscriptions.start_link(mailer: Mailer, name: :named_subscriptions)
      assert Process.whereis(:named_subscriptions) == pid
      assert Subscriptions.subscribers(:named_subscriptions, "t") == []
    end

    test "requires a mailer" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _}} =
               Subscriptions.start_link(name: :no_mailer_subscriptions)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for an unknown topic", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "subscribes a pid and an email address", %{server: server} do
      pid = spawn_idle()
      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", pid]
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
    test "returns :ok even with no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert flush(server, "empty") == []
    end

    test "sends a notification message to pid subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "sends to every pid subscriber", %{server: server} do
      parent = self()

      pids =
        for i <- 1..2 do
          spawn(fn ->
            receive do
              {:notification, _, _} = msg -> send(parent, {:got, i, msg})
            end
          end)
        end

      for pid <- pids, do: Subscriptions.subscribe(server, "news", pid)
      Subscriptions.publish(server, "news", :payload)

      assert_receive {:got, 1, {:notification, "news", :payload}}
      assert_receive {:got, 2, {:notification, "news", :payload}}
    end

    test "mails email subscribers through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
      refute_receive {:notification, _, _}, 20
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.publish(server, "news", :p)

      assert_receive {:notification, "news", :p}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "other", self())
      Subscriptions.subscribe(server, "other", "a@example.com")
      Subscriptions.publish(server, "news", :p)
      flush(server, "news")

      refute_receive {:notification, _, _}, 20
      refute_receive {:delivered, _, _}, 20
    end

    test "delivers each publish separately", %{server: server} do
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

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end

    test "it is removed from every topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "a", pid)
      Subscriptions.subscribe(server, "b", pid)

      send(pid, :stop)

      wait_until(fn ->
        Subscriptions.subscribers(server, "a") == [] and
          Subscriptions.subscribers(server, "b") == []
      end)
    end

    test "other pid subscribers are kept and still notified", %{server: server} do
      doomed = spawn_idle()
      Subscriptions.subscribe(server, "news", doomed)
      Subscriptions.subscribe(server, "news", self())

      ref = Process.monitor(doomed)
      Process.exit(doomed, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [self()] end)

      Subscriptions.publish(server, "news", :after)
      assert_receive {:notification, "news", :after}
    end

    test "a pid subscribed twice to a topic is fully removed", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", pid)

      send(pid, :stop)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "publishing after the exit does not crash the server", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      send(pid, :stop)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)

      Subscriptions.publish(server, "news", :late)
      assert flush(server, "news") == []
      assert Process.alive?(server)
    end

    test "the server survives a subscriber exiting abnormally", %{server: server} do
      pid = spawn(fn -> exit(:boom) end)
      Subscriptions.subscribe(server, "news", pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
      assert Process.alive?(server)
    end

    test "email subscribers are unaffected by process exits", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      send(pid, :stop)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["a@example.com"] end)
    end
  end
end
