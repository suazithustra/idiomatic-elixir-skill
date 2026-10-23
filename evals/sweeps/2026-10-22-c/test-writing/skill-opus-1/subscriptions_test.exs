ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
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
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps each topic's subscribers separate", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "sports", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ada@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["grace@example.com", self(), "ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed process", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{headline: "Launch"}) == :ok
      assert_receive {:notification, "news", %{headline: "Launch"}}
    end

    test "mails a subscribed email address with the topic in the subject", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert :ok = Subscriptions.publish(server, "news", %{headline: "Launch"})
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert :ok = Subscriptions.publish(server, "news", :launch)
      assert_receive {:notification, "news", :launch}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "sports", self())
      assert :ok = Subscriptions.subscribe(server, "sports", "ada@example.com")

      assert :ok = Subscriptions.publish(server, "news", :launch)

      # subscribers/2 is a call, so its reply means the publish cast was handled
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_and_exit]

    test "removes the process from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "still notifies the remaining subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :launch)
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    ref = Process.monitor(subscriber)

    assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
    assert :ok = Subscriptions.subscribe(server, "news", subscriber)
    assert :ok = Subscriptions.subscribe(server, "sports", subscriber)

    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
    :ok
  end
end
