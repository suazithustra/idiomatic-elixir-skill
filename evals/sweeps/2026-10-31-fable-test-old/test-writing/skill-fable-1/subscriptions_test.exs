ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @moduledoc false
    @behaviour Notify.Mailer

    # deliver/2 runs inside the server, so its registered name is the test's registry key.
    @impl true
    def deliver(to, subject) do
      {:registered_name, server} = Process.info(self(), :registered_name)
      [{test_pid, _value}] = Registry.lookup(TestMailer.Registry, server)
      send(test_pid, {:delivered, to, subject})
      :ok
    end
  end

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
    test "adds a process to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      Subscriptions.publish(server, "news", %{title: "Release 1.0"})

      assert_receive {:notification, "news", %{title: "Release 1.0"}}
    end

    test "mails a subscribed email address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      Subscriptions.publish(server, "news", %{title: "Release 1.0"})

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      Subscriptions.publish(server, "news", %{title: "Release 1.0"})

      assert_receive {:notification, "news", %{title: "Release 1.0"}}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "leaves subscribers of other topics alone", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      Subscriptions.publish(server, "sports", %{title: "Final score"})

      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ada@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ada@example.com"]
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_and_exit]

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "alerts") == []
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", %{title: "Release 1.0"})

      assert_receive {:notification, "news", %{title: "Release 1.0"}}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = spawn(&wait_for_stop/0)
    ref = Process.monitor(subscriber)
    :ok = Subscriptions.subscribe(server, "news", subscriber)
    :ok = Subscriptions.subscribe(server, "alerts", subscriber)
    :ok = Subscriptions.subscribe(server, "news", self())

    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
    :ok
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end
end
