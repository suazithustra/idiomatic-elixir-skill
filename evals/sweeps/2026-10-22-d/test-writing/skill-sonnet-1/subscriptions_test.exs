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

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :ignored) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", "hello") == :ok
      # a call returns only after the publish cast was handled
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "returns :ok for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "empty", "hello") == :ok
      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from the topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "removes it from every topic it joined", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps publishing to the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", "hello") == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
      refute_receive {:notification, _topic, _payload}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    exiting = spawn(fn -> receive(do: (:stop -> :ok)) end)
    ref = Process.monitor(exiting)

    assert Subscriptions.subscribe(server, "news", exiting) == :ok
    assert Subscriptions.subscribe(server, "sports", exiting) == :ok
    assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

    send(exiting, :stop)
    assert_receive {:DOWN, ^ref, :process, ^exiting, :normal}

    # the server's own :DOWN is handled before this call is answered
    assert Subscriptions.subscribers(server, "news") != []
    :ok
  end
end
