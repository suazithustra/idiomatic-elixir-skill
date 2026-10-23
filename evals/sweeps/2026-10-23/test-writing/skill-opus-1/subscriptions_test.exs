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
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "leaves the subscribers of other topics unchanged", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "lin@example.com")

      assert Subscriptions.subscribers(server, "news") == ["lin@example.com", "ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to a subscribed process", %{server: server} do
      payload = %{headline: "Release notes"}
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", payload)

      assert_receive {:notification, "news", ^payload}
    end

    test "mails each subscribed address with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "lin@example.com")
      Subscriptions.publish(server, "news", %{headline: "Release notes"})

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "lin@example.com", "New on news"}
    end

    test "notifies only the subscribers of the published topic", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "ada@example.com")
      Subscriptions.publish(server, "news", %{headline: "Release notes"})
      # publish/3 is a cast; the server answers this call only after handling it
      :sys.get_state(server)

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes the process from all its topics", %{server: server, subscriber: subscriber} do
      refute subscriber in Subscriptions.subscribers(server, "news")
      refute subscriber in Subscriptions.subscribers(server, "sports")
    end

    test "keeps the other subscribers of its topics", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Agent, fn -> nil end})
    Subscriptions.subscribe(server, "news", self())
    Subscriptions.subscribe(server, "news", subscriber)
    Subscriptions.subscribe(server, "sports", subscriber)

    ref = Process.monitor(subscriber)
    stop_supervised!(Agent)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :shutdown}

    %{subscriber: subscriber}
  end
end
