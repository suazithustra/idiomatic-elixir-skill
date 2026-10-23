ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.SubscriptionsTest.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.SubscriptionsTest.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  defp start_idle_process do
    spec = Supervisor.child_spec({Agent, fn -> :ok end}, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  defp kill_and_await_exit(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "empty") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", self(), "ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", :ignored)
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", "bob@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "ann@example.com")

      Subscriptions.publish(server, "news", :hello)
      # a call is handled after the earlier publish cast
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "succeeds when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid = start_idle_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "news", self())
      kill_and_await_exit(pid)
      %{pid: pid}
    end

    test "removes it from every topic", %{server: server, pid: pid} do
      refute pid in Subscriptions.subscribers(server, "news")
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self(), "ann@example.com"]
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end
  end

  test "an exiting process that was subscribed to nothing does not affect the server", %{
    server: server
  } do
    Subscriptions.subscribe(server, "news", "ann@example.com")
    kill_and_await_exit(start_idle_process())

    assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
  end
end
