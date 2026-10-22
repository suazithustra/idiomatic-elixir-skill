ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @moduledoc false
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

    test "leaves other topics unchanged", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "grace@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") ==
               ["grace@example.com", self(), "ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{headline: "Elixir 2.0"}) == :ok
      assert_receive {:notification, "news", %{headline: "Elixir 2.0"}}
    end

    test "mails a subscribed email address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", %{headline: "Elixir 2.0"}) == :ok
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies nobody subscribed only to another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", :update) == :ok

      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from every topic and keeps the other subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "still notifies the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :update) == :ok
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Task, fn -> wait_for_stop() end})

    assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
    assert Subscriptions.subscribe(server, "news", subscriber) == :ok
    assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

    ref = Process.monitor(subscriber)
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
