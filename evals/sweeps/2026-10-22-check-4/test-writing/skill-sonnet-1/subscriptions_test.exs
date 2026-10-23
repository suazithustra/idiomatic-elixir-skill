ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the test's key
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

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  defp spawn_subscriber do
    test_pid = self()

    pid =
      spawn(fn ->
        send(test_pid, :subscriber_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :subscriber_ready
    pid
  end

  describe "start_link/1" do
    test "fails to start without a mailer", %{module: module, test: test} do
      name = Module.concat([module, test, WithoutMailer])

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child_spec}} =
               start_supervised(
                 Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)
               )
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers of a topic, most recent first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", self(), "a@example.com"]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)
      # a call is handled after the earlier publish cast
      _ = Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "news", :hello)

      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:delivered, _to, _subject}
    end

    test "notifies a process once per subscription", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:notification, "news", :hello}
      refute_receive {:notification, "news", :hello}, 50
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sports", pid)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      %{pid: pid}
    end

    test "removes it from every topic and keeps the others", %{server: server, pid: pid} do
      exit_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes it when it is killed", %{server: server, pid: pid} do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "keeps publishing to the remaining subscribers", %{server: server, pid: pid} do
      exit_and_wait(pid)

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "keeps the server running", %{server: server, pid: pid} do
      exit_and_wait(pid)

      assert Process.alive?(server)
    end
  end

  defp exit_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
