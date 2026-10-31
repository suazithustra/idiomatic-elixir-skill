ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the key the test
  # registered itself under. This keeps the test process out of global state.
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

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})}
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

  describe "publish/3" do
    test "sends a notification to each subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{title: "Hello"}) == :ok
      assert_receive {:notification, "news", %{title: "Hello"}}
    end

    test "mails each subscribed address with the topic as subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "b@example.com") == :ok
      assert Subscriptions.publish(server, "news", %{title: "Hello"}) == :ok
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.publish(server, "news", :payload) == :ok
      assert_receive {:notification, "news", :payload}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "sports", :sports_payload) == :ok
      assert Subscriptions.publish(server, "news", :news_payload) == :ok

      # The server handles casts in order, so once the "news" notification has
      # arrived, a "sports" one would already be in the mailbox if it had been sent.
      assert_receive {:notification, "news", :news_payload}
      refute_received {:notification, "sports", _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["a@example.com", self()]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "a@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["a@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from the subscribers of every topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "still notifies the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :payload) == :ok
      assert_receive {:notification, "news", :payload}
    end

    defp subscribe_and_exit(%{server: server}) do
      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      :ok
    end
  end
end
