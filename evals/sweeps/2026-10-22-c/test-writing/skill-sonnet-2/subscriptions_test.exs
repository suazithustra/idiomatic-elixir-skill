ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry __MODULE__.Registry

  def registry, do: @registry

  # deliver/2 runs inside the server, so its registered name is the test's key
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(@registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.registry()})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.registry(), name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp kill_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  describe "start_link/1" do
    test "fails without a mailer" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _stacktrace}} =
               Subscriptions.start_link(name: nil)
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      assert :ok = Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", self(), "ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address with the topic in the subject", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.publish(server, "news", :ignored) == :ok
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "sports", self())
      assert :ok = Subscriptions.subscribe(server, "sports", "ann@example.com")

      Subscriptions.publish(server, "news", :update)
      # a synchronous call returns after the publish cast was handled
      _state = :sys.get_state(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :update) == :ok
      assert %{topics: topics} = :sys.get_state(server)
      assert topics == %{}
    end

    test "notifies each publication separately", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", 1)
      Subscriptions.publish(server, "news", 2)

      assert_receive {:notification, "news", 1}
      assert_receive {:notification, "news", 2}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn_subscriber()
      assert :ok = Subscriptions.subscribe(server, "news", subscriber)
      assert :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      %{subscriber: subscriber}
    end

    test "it is removed from the topic", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", subscriber]

      kill_and_wait(subscriber)
      _state = :sys.get_state(server)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "it is removed from every topic", %{server: server, subscriber: subscriber} do
      assert :ok = Subscriptions.subscribe(server, "sports", subscriber)

      kill_and_wait(subscriber)
      _state = :sys.get_state(server)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "it is removed after a normal exit", %{server: server, subscriber: subscriber} do
      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
      _state = :sys.get_state(server)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "the server keeps running and still mails email subscribers", %{
      server: server,
      subscriber: subscriber
    } do
      kill_and_wait(subscriber)

      Subscriptions.publish(server, "news", :update)

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert Process.alive?(server)
    end
  end
end
