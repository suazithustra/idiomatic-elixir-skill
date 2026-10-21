ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the server, so its registered name is the key the test registered under.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{test: name} do
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  defp start_subscriber(id) do
    spec = Supervisor.child_spec({Agent, fn -> nil end}, id: id, restart: :temporary)
    start_supervised!(spec)
  end

  defp stop_and_await_exit(pid) do
    ref = Process.monitor(pid)
    Agent.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  describe "start_link/1" do
    test "fails when no mailer is given", %{test: name} do
      spec = Supervisor.child_spec({Subscriptions, name: {:global, name}}, id: :no_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _spec}} = start_supervised(spec)
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert [pid] = Subscriptions.subscribers(server, "news")
      assert pid == self()
    end

    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ana@example.com")
      assert ["ana@example.com"] = Subscriptions.subscribers(server, "news")
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ana@example.com")
      Subscriptions.subscribe(server, "sports", "bo@example.com")

      assert ["ana@example.com"] = Subscriptions.subscribers(server, "news")
      assert ["bo@example.com"] = Subscriptions.subscribers(server, "sports")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert [] = Subscriptions.subscribers(server, "empty")
    end

    test "returns subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ana@example.com")

      Subscriptions.publish(server, "news", %{id: 1})
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      other = start_subscriber(:other)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", other)
      Subscriptions.subscribe(server, "news", "ana@example.com")
      Subscriptions.subscribe(server, "news", "bo@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ana@example.com", "New on news"}
      assert_receive {:delivered, "bo@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "bo@example.com")

      Subscriptions.publish(server, "news", :hello)
      # The state call returns after the server has handled the publish.
      :sys.get_state(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert %{topics: topics} = :sys.get_state(server)
      assert topics == %{}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = start_subscriber(:subscriber)
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "ana@example.com")
      Subscriptions.subscribe(server, "sports", subscriber)

      stop_and_await_exit(subscriber)
      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server, subscriber: subscriber} do
      refute subscriber in Subscriptions.subscribers(server, "news")
      assert [] = Subscriptions.subscribers(server, "sports")
    end

    test "keeps the other subscribers", %{server: server} do
      assert ["ana@example.com"] = Subscriptions.subscribers(server, "news")
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "keeps the server running", %{server: server} do
      assert Process.alive?(GenServer.whereis(server))
    end
  end

  describe "when a process subscribed twice exits" do
    test "removes both entries", %{server: server} do
      subscriber = start_subscriber(:twice)
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", subscriber)

      stop_and_await_exit(subscriber)

      assert [] = Subscriptions.subscribers(server, "news")
    end
  end
end
