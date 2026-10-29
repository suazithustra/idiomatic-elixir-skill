ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the Subscriptions server, so the server's registered name
  # identifies the test that started it.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.TestMailer.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "b@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["b@example.com", "a@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns only the subscribers of the requested topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "publish/3 to pid subscribers" do
    test "sends the payload to each subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{headline: "Launch"}) == :ok
      assert_receive {:notification, "news", %{headline: "Launch"}}
    end

    test "does not send to pids subscribed to other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok

      assert Subscriptions.publish(server, "news", "Launch") == :ok
      sync(server)

      refute_received {:notification, _topic, _payload}
    end

    test "does nothing for a topic with no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", "Launch") == :ok
      sync(server)

      assert Process.alive?(server)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails the address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", "Launch") == :ok
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "mails and notifies a mixed list of subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", "Launch") == :ok
      assert_receive {:notification, "news", "Launch"}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not mail addresses subscribed to other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", "Launch") == :ok
      sync(server)

      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    test "removes the pid when it stops normally", %{server: server} do
      pid = idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribers(server, "news") == [pid]

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      await_subscribers(server, "news", [])
    end

    test "removes the pid when it crashes", %{server: server} do
      pid = idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      ref = Process.monitor(pid)
      Process.exit(pid, :boom)
      assert_receive {:DOWN, ^ref, :process, ^pid, :boom}

      await_subscribers(server, "news", [])
    end

    test "removes the pid from every topic it subscribed to", %{server: server} do
      pid = idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sports", pid) == :ok

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      await_subscribers(server, "news", [])
      await_subscribers(server, "sports", [])
    end

    test "keeps the email subscribers of the topic", %{server: server} do
      pid = idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      await_subscribers(server, "news", ["ada@example.com"])
    end
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # publish/3 is a cast. A call returns only after the server has handled the
  # cast, so anything it sent is already in this process's mailbox.
  defp sync(server), do: :sys.get_state(server)

  # The server's own :DOWN message arrives separately from the one the test
  # receives, so the removal may not have happened yet. Poll for it briefly.
  defp await_subscribers(server, topic, expected, attempts \\ 100) do
    subscribers = Subscriptions.subscribers(server, topic)

    cond do
      subscribers == expected ->
        :ok

      attempts == 0 ->
        flunk("expected #{inspect(expected)}, got #{inspect(subscribers)}")

      true ->
        Process.sleep(5)
        await_subscribers(server, topic, expected, attempts - 1)
    end
  end
end
