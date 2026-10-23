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

  describe "subscribe/3" do
    test "returns :ok", %{server: server} do
      assert :ok == Subscriptions.subscribe(server, "news", self())
    end

    test "adds a pid to the topic's subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps subscriptions to other topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok == Subscriptions.publish(server, "news", %{headline: "Hello"})

      assert_receive {:notification, "news", %{headline: "Hello"}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", %{headline: "Hello"})

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ann@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "bob@example.com")

      Subscriptions.publish(server, "news", :update)
      # a synchronous call returns only after the publish cast was handled
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok == Subscriptions.publish(server, "news", :update)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers notified", %{server: server} do
      Subscriptions.publish(server, "news", :update)

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "survives publishing to the topic the process left", %{server: server} do
      Subscriptions.publish(server, "sports", :update)

      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(subscriber)

    Subscriptions.subscribe(server, "news", "ann@example.com")
    Subscriptions.subscribe(server, "news", subscriber)
    Subscriptions.subscribe(server, "sports", subscriber)

    Process.exit(subscriber, :kill)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

    %{subscriber: subscriber}
  end
end
