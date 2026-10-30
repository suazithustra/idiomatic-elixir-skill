ExUnit.start()

defmodule Notify.Subscriptions.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.Subscriptions.TestMailer.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.Subscriptions.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: name})}
  end

  describe "start_link/1" do
    test "fails without a :mailer option", context do
      name = Module.concat([context.module, context.test, WithoutMailer])
      spec = Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} = start_supervised(spec)
    end
  end

  describe "subscribe/3" do
    test "returns :ok for a pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
    end

    test "returns :ok for an email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
    end

    test "adds the subscriber to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "bo@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") ==
               ["bo@example.com", self(), "ana@example.com"]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "bo@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bo@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok
      assert Subscriptions.subscribers(server, "news") == []

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "succeeds for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :update) == :ok
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server, subscriber: subscriber} do
      assert subscriber not in Subscriptions.subscribers(server, "news")
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the email subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "keeps publishing to the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:delivered, "ana@example.com", "New on news"}
    end
  end
end
