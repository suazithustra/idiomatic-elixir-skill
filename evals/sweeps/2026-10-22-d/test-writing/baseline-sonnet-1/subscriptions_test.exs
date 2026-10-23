ExUnit.start()

defmodule Notify.TestMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    case :persistent_term.get({__MODULE__, :sink}, nil) do
      nil -> :ok
      sink -> send(sink, {:delivered, to, subject})
    end

    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    :persistent_term.put({Notify.TestMailer, :sink}, self())
    on_exit(fn -> :persistent_term.erase({Notify.TestMailer, :sink}) end)

    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: nil} |> child_spec())
    %{server: server}
  end

  defp child_spec({_mod, opts}) do
    # name: nil is not valid for GenServer, so use a unique name per test
    name = :"subs_#{System.unique_integer([:positive])}"

    %{
      id: name,
      start: {Subscriptions, :start_link, [Keyword.put(opts, :name, name)]}
    }
  end

  # `publish/3` is a cast; a following call to the same server is processed after it.
  defp sync(server), do: Subscriptions.subscribers(server, "__sync__")

  defp spawn_subscriber do
    parent = self()

    spawn(fn ->
      receive do
        :stop -> :ok
        {:notification, _, _} = msg -> send(parent, {:got, self(), msg})
      end
    end)
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  describe "start_link/1" do
    test "requires a mailer" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = Subscriptions.start_link(name: :no_mailer_subs)
    end

    test "registers under the given name" do
      name = :named_subs_test
      start_supervised!(%{id: name, start: {Subscriptions, :start_link, [[mailer: Notify.TestMailer, name: name]]}})
      assert Process.whereis(name) != nil
      assert Subscriptions.subscribers(name, "t") == []
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "subscribing returns :ok and records the subscriber", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", self(), "a@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "a", "a@example.com")
      :ok = Subscriptions.subscribe(server, "b", "b@example.com")

      assert Subscriptions.subscribers(server, "a") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "b") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "returns :ok immediately", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :hello)
    end

    test "sends a notification message to pid subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "delivers an email through the mailer to email subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.publish(server, "news", :payload)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies both pid and email subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")
      :ok = Subscriptions.publish(server, "news", 42)

      assert_receive {:notification, "news", 42}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "other", self())
      :ok = Subscriptions.subscribe(server, "other", "o@example.com")
      :ok = Subscriptions.publish(server, "news", :x)
      sync(server)

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "publishing to a topic with no subscribers does nothing", %{server: server} do
      :ok = Subscriptions.publish(server, "nobody", :x)
      sync(server)

      refute_received _
      assert Process.alive?(server)
    end

    test "each publish produces a separate notification", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", 1)
      :ok = Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end

    test "a pid subscribed to several topics gets only the matching one", %{server: server} do
      :ok = Subscriptions.subscribe(server, "a", self())
      :ok = Subscriptions.subscribe(server, "b", self())
      :ok = Subscriptions.publish(server, "a", :one)
      sync(server)

      assert_received {:notification, "a", :one}
      refute_received {:notification, "b", _}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      assert Subscriptions.subscribers(server, "news") == [pid]

      stop_and_wait(pid)
      sync(server)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "it is removed from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "a", pid)
      :ok = Subscriptions.subscribe(server, "b", pid)

      stop_and_wait(pid)
      sync(server)

      assert Subscriptions.subscribers(server, "a") == []
      assert Subscriptions.subscribers(server, "b") == []
    end

    test "other subscribers are kept", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", self())

      stop_and_wait(pid)
      sync(server)

      assert Subscriptions.subscribers(server, "news") == [self(), "a@example.com"]
    end

    test "it is removed when it crashes", %{server: server} do
      pid = spawn(fn -> receive do: (:crash -> exit(:boom)) end)
      :ok = Subscriptions.subscribe(server, "news", pid)

      ref = Process.monitor(pid)
      send(pid, :crash)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}
      sync(server)

      assert Subscriptions.subscribers(server, "news") == []
      assert Process.alive?(server)
    end

    test "publishing afterwards does not notify the dead process", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", self())

      stop_and_wait(pid)
      sync(server)

      :ok = Subscriptions.publish(server, "news", :after)
      assert_receive {:notification, "news", :after}
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "subscribing an already-dead pid gets it cleaned up", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      :ok = Subscriptions.subscribe(server, "news", pid)
      sync(server)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end
end
