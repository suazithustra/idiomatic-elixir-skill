ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

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
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", self(), "ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      # subscribers/2 is a call, so the server has handled the publish cast before it replies
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}, 0
      refute_receive {:delivered, _to, _subject}, 0
    end

    test "does nothing for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}, 0
      refute_receive {:delivered, _to, _subject}, 0
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from the topic", %{server: server, email: email} do
      assert Subscriptions.subscribers(server, "news") == [email]
    end

    test "stops notifying it, and still mails the others", %{server: server, email: email} do
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:delivered, ^email, "New on news"}
      assert Subscriptions.subscribers(server, "news") == [email]
    end

    test "removes it from every topic it was subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the server running", %{server: server} do
      assert Process.alive?(server)
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    email = "ann@example.com"
    subscriber = spawn(fn -> wait_for_stop() end)

    assert Subscriptions.subscribe(server, "news", subscriber) == :ok
    assert Subscriptions.subscribe(server, "sports", subscriber) == :ok
    assert Subscriptions.subscribe(server, "news", email) == :ok

    ref = Process.monitor(subscriber)
    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

    %{email: email}
  end

  defp wait_for_stop do
    receive do
      :stop -> :ok
    end
  end
end
