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

  import ExUnit.CaptureLog

  alias Notify.{Subscriptions, TestMailer}

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: name}
  end

  describe "start_link/1" do
    test "requires the :mailer option", context do
      # The setup already runs a server under the test-specific name, and both
      # children share the id Notify.Subscriptions, so this one needs its own id.
      name = Module.concat(context.module, :without_mailer)

      capture_log(fn ->
        send(
          self(),
          {:start_result, start_supervised({Subscriptions, name: name}, id: :no_mailer)}
        )
      end)

      assert_received {:start_result, {:error, {{%KeyError{key: :mailer}, _stacktrace}, _spec}}}
    end
  end

  describe "subscribe/3" do
    test "adds a pid to the topic's subscribers", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the notification to every subscribed pid", %{server: server} do
      listener = spawn_listener(self())
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", listener)

      assert :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:heard, ^listener, {:notification, "news", :hello}}
    end

    test "delivers to email subscribers through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")

      assert :ok = Subscriptions.publish(server, "news", :hello)

      wait_for_server(server)
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :hello)

      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns the subscribers most recent first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", "a@example.com"]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end

    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = Subscriptions.subscribe(server, "news", subscriber)
      %{subscriber: subscriber}
    end

    test "removes the process after it stops normally", %{server: server, subscriber: subscriber} do
      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      wait_for_server(server)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process after it is killed", %{server: server, subscriber: subscriber} do
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      wait_for_server(server)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process from every topic it subscribed to",
         %{server: server, subscriber: subscriber} do
      :ok = Subscriptions.subscribe(server, "sports", subscriber)
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      wait_for_server(server)
      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server, subscriber: subscriber} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      wait_for_server(server)
      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
    end
  end

  # Subscriptions handles its own :DOWN messages in order. A call to it returns
  # only after those, and any notifications sent before it, have been processed.
  defp wait_for_server(server), do: Subscriptions.subscribers(server, "news")

  defp spawn_listener(test_pid) do
    spawn(fn ->
      receive do
        message -> send(test_pid, {:heard, self(), message})
      end
    end)
  end
end

