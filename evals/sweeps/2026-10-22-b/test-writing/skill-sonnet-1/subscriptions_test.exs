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

  describe "start_link/1" do
    test "fails without a mailer", context do
      name = Module.concat(context.module, "#{context.test} without mailer")

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child_spec}} =
               start_supervised(
                 Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)
               )
    end
  end

  describe "subscribers/2" do
    test "is empty for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", self(), "a@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the notification to a process subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      other = spawn_link(&relay_notifications/0)
      send(other, {:forward_to, self()})

      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", other)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:relayed, {:notification, "news", :hello}}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)
      # a call is handled after the earlier publish cast
      _ = Subscriptions.subscribers(server, "news")

      refute_receive {:notification, _topic, _payload}, 50
      refute_receive {:delivered, _to, _subject}, 50
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from the topic", %{server: server, survivor: survivor} do
      assert Subscriptions.subscribers(server, "news") == [survivor]
    end

    test "removes it from every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps notifying the remaining subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert Process.alive?(server)
    end
  end

  # Subscribes a doomed process to two topics next to the test process, then waits
  # until the process is gone and the server has handled its :DOWN message.
  defp subscribe_and_exit(%{server: server}) do
    doomed = spawn(fn -> receive do: (:stop -> :ok) end)

    :ok = Subscriptions.subscribe(server, "news", doomed)
    :ok = Subscriptions.subscribe(server, "sports", doomed)
    :ok = Subscriptions.subscribe(server, "news", self())

    ref = Process.monitor(doomed)
    send(doomed, :stop)
    assert_receive {:DOWN, ^ref, :process, ^doomed, :normal}

    # the server monitors the same process; a state read orders after its :DOWN
    _ = :sys.get_state(server)

    %{survivor: self()}
  end

  defp relay_notifications do
    receive do
      {:forward_to, test_pid} -> relay_notifications(test_pid)
    end
  end

  defp relay_notifications(test_pid) do
    receive do
      message ->
        send(test_pid, {:relayed, message})
        relay_notifications(test_pid)
    end
  end
end
