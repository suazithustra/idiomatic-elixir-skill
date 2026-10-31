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
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "b@example.com")

      expected = ["b@example.com", self(), "a@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["a@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to a subscribed process", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", {:article, 42}) == :ok

      assert_receive {:notification, "news", {:article, 42}}
    end

    test "sends a notification to every subscribed process", %{server: server} do
      first = start_subscriber(:first)
      second = start_subscriber(:second)
      Subscriptions.subscribe(server, "news", first)
      Subscriptions.subscribe(server, "news", second)

      Subscriptions.publish(server, "news", {:article, 42})

      assert_receive {:forwarded, ^first, {:notification, "news", {:article, 42}}}
      assert_receive {:forwarded, ^second, {:notification, "news", {:article, 42}}}
    end

    test "mails a subscribed address a subject naming the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", {:article, 42})

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies the processes and addresses of one topic alike", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "news", {:article, 42})

      assert_receive {:notification, "news", {:article, 42}}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      Subscriptions.publish(server, "sports", {:match, 7})

      # The server handles messages in order, so this reply means the publish was handled
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "reaches the remaining subscribers after a failed delivery", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "bounced@example.com")

      Subscriptions.publish(server, "news", {:article, 42})

      assert_receive {:delivered, "bounced@example.com", "New on news"}
      assert_receive {:notification, "news", {:article, 42}}
    end
  end

  describe "when a subscribed process exits" do
    setup [:trace_server, :subscribe_process]

    test "removes a process that stopped normally", %{server: server, subscriber: subscriber} do
      send(subscriber, :stop)
      assert_server_receives_down(server, subscriber, :normal)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a process that was killed", %{server: server, subscriber: subscriber} do
      Process.exit(subscriber, :kill)
      assert_server_receives_down(server, subscriber, :killed)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a process from every topic", %{server: server, subscriber: subscriber} do
      Subscriptions.subscribe(server, "sports", subscriber)

      send(subscriber, :stop)
      assert_server_receives_down(server, subscriber, :normal)
      assert_server_receives_down(server, subscriber, :normal)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes a process subscribed twice", %{server: server, subscriber: subscriber} do
      Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)
      assert_server_receives_down(server, subscriber, :normal)
      assert_server_receives_down(server, subscriber, :normal)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a process that was dead when it subscribed", context do
      %{server: server, subscriber: subscriber} = context
      send(subscriber, :stop)
      assert_server_receives_down(server, subscriber, :normal)

      Subscriptions.subscribe(server, "sports", subscriber)
      assert_server_receives_down(server, subscriber, :noproc)

      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, subscriber: subscriber} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      send(subscriber, :stop)
      assert_server_receives_down(server, subscriber, :normal)

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end

    test "still notifies the other subscribers", %{server: server, subscriber: subscriber} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")

      send(subscriber, :stop)
      assert_server_receives_down(server, subscriber, :normal)
      Subscriptions.publish(server, "news", {:article, 42})

      assert_receive {:notification, "news", {:article, 42}}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end
  end

  # The server and this test would each get their own :DOWN, in no guaranteed order, so a monitor
  # here cannot say when the server has its copy. Tracing the server can: a call made after the
  # trace message arrives is handled after the :DOWN.
  defp trace_server(%{server: server}) do
    :erlang.trace(server, true, [:receive])
    :ok
  end

  defp subscribe_process(%{server: server}) do
    subscriber = start_subscriber(:subscriber)
    Subscriptions.subscribe(server, "news", subscriber)
    %{subscriber: subscriber}
  end

  defp assert_server_receives_down(server, subscriber, reason) do
    assert_receive {:trace, ^server, :receive, {:DOWN, _ref, :process, ^subscriber, ^reason}}
  end

  defp start_subscriber(id) do
    test_pid = self()
    start_supervised!({Task, fn -> forward_notifications(test_pid) end}, id: id)
  end

  defp forward_notifications(test_pid) do
    receive do
      {:notification, _topic, _payload} = notification ->
        send(test_pid, {:forwarded, self(), notification})
        forward_notifications(test_pid)

      :stop ->
        :ok
    end
  end
end
