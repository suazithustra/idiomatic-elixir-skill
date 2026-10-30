ExUnit.start()

defmodule Notify.SubscriptionsTest do
  # Not async: the mailer sink is a global key.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  defmodule TestMailer do
    @behaviour Notify.Mailer

    # `deliver/2` runs inside the server and the mailer has no state, so the
    # test process is stored in a global `:persistent_term` key and notified from there.
    @impl true
    def deliver(to, subject) do
      case :persistent_term.get({__MODULE__, :sink}, nil) do
        nil -> :ok
        sink -> send(sink, {:delivered, to, subject})
      end

      :ok
    end
  end

  setup do
    # Each test gets its own server; the mailer sink is shared, so tests that
    # use it are grouped under a single describe and the key is reset here.
    :persistent_term.put({TestMailer, :sink}, self())
    on_exit(fn -> :persistent_term.erase({TestMailer, :sink}) end)

    server = start_supervised!({Subscriptions, mailer: TestMailer, name: nil_name()})
    %{server: server}
  end

  # start_link/1 always registers a name, so give each test a unique one.
  defp nil_name, do: :"subscriptions_#{System.unique_integer([:positive])}"

  defp spawn_idle do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      true ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      _ ->
        flunk("condition not met in time")
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "an unknown topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    test "lists pid and email subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")
      Subscriptions.subscribe(server, "news", "third@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["third@example.com", "second@example.com", "first@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3 to process subscribers" do
    test "sends a notification message", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "notifies every subscriber of the topic", %{server: server} do
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

      for n <- 1..3 do
        assert_receive {:got, ^n, {:notification, "news", :hello}}
      end

      assert length(pids) == 3
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())

      Subscriptions.publish(server, "news", :hello)
      # Ensure the publish has been processed before asserting absence.
      Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _, _}, 50
    end

    test "publishing to a topic with no subscribers is fine", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "a pid subscribed twice is notified twice", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:notification, "news", :hello}
    end
  end

  describe "publish/3 to email subscribers" do
    test "delivers an email through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "delivers to every email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", _}
      assert_receive {:delivered, "b@example.com", _}
    end

    test "does not email subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", "a@example.com")

      Subscriptions.publish(server, "news", :hello)
      Subscriptions.subscribers(server, "news")

      refute_receive {:delivered, _, _}, 50
    end

    test "handles pid and email subscribers on the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      Process.exit(pid, :kill)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "it is removed from every topic it was subscribed to", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      Process.exit(pid, :kill)

      eventually(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "other subscribers are kept", %{server: server} do
      pid = spawn_idle()
      other = spawn_idle()
      Subscriptions.subscribe(server, "news", other)
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      eventually(fn -> pid not in Subscriptions.subscribers(server, "news") end)
      assert Subscriptions.subscribers(server, "news") == ["a@example.com", other]
    end

    test "it is removed after a normal exit too", %{server: server} do
      pid = spawn(fn -> receive do: (:stop -> :ok) end)
      Subscriptions.subscribe(server, "news", pid)

      send(pid, :stop)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "a pid that is already dead is removed right after subscribing", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      Subscriptions.subscribe(server, "news", pid)

      eventually(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "publishing afterwards does not notify the dead process and the server survives",
         %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Process.exit(pid, :kill)
      eventually(fn -> pid not in Subscriptions.subscribers(server, "news") end)

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert Process.alive?(GenServer.whereis(server))
    end

    test "email subscribers are unaffected by process exits", %{server: server} do
      pid = spawn_idle()
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", pid)
      Process.exit(pid, :kill)
      eventually(fn -> pid not in Subscriptions.subscribers(server, "news") end)

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end
  end
end
