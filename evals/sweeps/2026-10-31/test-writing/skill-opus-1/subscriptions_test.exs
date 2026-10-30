ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the test's key
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
    send(test_pid, {:delivered, to, subject})
    delivery_result(to)
  end

  defp delivery_result("bounced@example.com"), do: {:error, :bounced}
  defp delivery_result(_to), do: :ok
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
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a subscribed pid the topic and the payload", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies the pids and the addresses of one topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "ben@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launch) == :ok

      assert_receive {:notification, "news", :launch}
      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "ben@example.com", "New on news"}
    end

    test "leaves the subscribers of other topics alone", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launch) == :ok

      # Answered after the publish, so anything the server sent for it has arrived
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "mails the other addresses when one delivery fails", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bounced@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "ben@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launch) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bounced@example.com", "New on news"}
      assert_receive {:delivered, "ben@example.com", "New on news"}
    end
  end

  describe "subscribers/2" do
    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ben@example.com") == :ok

      expected = ["ben@example.com", self(), "ann@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "ben@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["ben@example.com"]
    end

    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup [:trace_server, :start_subscriber]

    test "removes a process that stops normally", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      send(subscriber, :stop)

      assert_server_saw_exit(server, subscriber, :normal)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a process that is killed", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      Process.exit(subscriber, :kill)

      assert_server_saw_exit(server, subscriber, :killed)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      send(subscriber, :stop)

      assert_server_saw_exit(server, subscriber, :normal)
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "removes the process from every topic", %{server: server, subscriber: subscriber} do
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

      send(subscriber, :stop)

      assert_server_saw_exit(server, subscriber, :normal)
      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes both entries of a process that subscribed twice", context do
      %{server: server, subscriber: subscriber} = context
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      send(subscriber, :stop)

      # Each subscription has its own monitor, and each monitor removes one entry
      assert_server_saw_exit(server, subscriber, :normal)
      assert_server_saw_exit(server, subscriber, :normal)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a process that exited before it subscribed", context do
      %{server: server, subscriber: subscriber} = context
      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      assert_server_saw_exit(server, subscriber, :noproc)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  # An exit reaches the server and the test separately, so a :DOWN in the test would not show
  # that the server has its own. Tracing shows the server receive it, and a call made after
  # that is handled after it.
  defp trace_server(%{server: server}) do
    :erlang.trace(server, true, [:receive])
    :ok
  end

  defp start_subscriber(_context) do
    wait_for_stop = fn ->
      receive do
        :stop -> :ok
      end
    end

    %{subscriber: start_supervised!({Task, wait_for_stop})}
  end

  defp assert_server_saw_exit(server, subscriber, reason) do
    assert_receive {:trace, ^server, :receive, {:DOWN, _ref, :process, ^subscriber, ^reason}}
  end
end
