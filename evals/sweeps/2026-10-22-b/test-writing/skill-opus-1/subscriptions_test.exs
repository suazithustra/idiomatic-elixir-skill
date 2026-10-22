ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so its registered name is the test's key
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(__MODULE__.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
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
    test "adds a pid to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps the subscribers of other topics unchanged", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["grace@example.com", self(), "ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to subscribed processes", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails subscribed email addresses through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "news", "grace@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_and_exit]

    test "removes it from the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the server running and notifying the remaining subscribers",
         %{server: server} do
      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Task, fn -> receive(do: (:stop -> :ok)) end})
    :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
    :ok = Subscriptions.subscribe(server, "news", subscriber)
    :ok = Subscriptions.subscribe(server, "sports", subscriber)

    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
    :ok
  end
end
