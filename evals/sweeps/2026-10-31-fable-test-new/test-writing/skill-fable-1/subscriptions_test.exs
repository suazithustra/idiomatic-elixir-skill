ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  def registry, do: @registry

  # deliver/2 runs inside the server, so its registered name is the test's registry key.
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
  alias Notify.TestMailer

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
    test "adds the calling process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ops@example.com"]
    end

    test "keeps the subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "alerts", "ops@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "alerts") == ["ops@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the payload to each subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{title: "Release 2.0"}) == :ok
      assert_receive {:notification, "news", %{title: "Release 2.0"}}
    end

    test "mails each email subscriber with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.publish(server, "news", %{title: "Release 2.0"}) == :ok
      assert_receive {:delivered, "ops@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.publish(server, "news", :released) == :ok
      assert_receive {:notification, "news", :released}
      assert_receive {:delivered, "ops@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ops@example.com") == :ok
      assert Subscriptions.publish(server, "alerts", :released) == :ok

      # A synchronous call returns after the server handled the publish cast.
      :sys.get_state(server)
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "first@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "last@example.com") == :ok

      newest_first = ["last@example.com", self(), "first@example.com"]
      assert Subscriptions.subscribers(server, "news") == newest_first
    end
  end

  describe "when a subscribed process exits" do
    setup [:subscribe_and_exit]

    test "removes it from every topic it subscribed to", %{server: server, exited: exited} do
      refute exited in Subscriptions.subscribers(server, "news")
      assert Subscriptions.subscribers(server, "alerts") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self(), "ops@example.com"]
    end

    test "still notifies the other subscribers of the topic", %{server: server} do
      assert Subscriptions.publish(server, "news", :released) == :ok
      assert_receive {:notification, "news", :released}
      assert_receive {:delivered, "ops@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    exited = spawn(fn -> receive(do: (:stop -> :ok)) end)
    ref = Process.monitor(exited)

    :ok = Subscriptions.subscribe(server, "news", "ops@example.com")
    :ok = Subscriptions.subscribe(server, "news", self())
    :ok = Subscriptions.subscribe(server, "news", exited)
    :ok = Subscriptions.subscribe(server, "alerts", exited)

    send(exited, :stop)
    assert_receive {:DOWN, ^ref, :process, ^exited, :normal}

    %{exited: exited}
  end
end
