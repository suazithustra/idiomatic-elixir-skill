ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry __MODULE__.Registry

  def registry, do: @registry

  # deliver/2 runs inside the server, so the server's registered name is the test's key.
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
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: server}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ada@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ada@example.com"]
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

      expected = ["last@example.com", self(), "first@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end
  end

  describe "publish/3 to a process subscriber" do
    setup %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      :ok
    end

    test "sends the topic and payload to the pid", %{server: server} do
      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not send messages published on other topics", %{server: server} do
      assert Subscriptions.publish(server, "sports", :goal) == :ok

      # The call is handled after the publish, so the cast has been processed by now.
      assert Subscriptions.subscribers(server, "news") == [self()]
      refute_received {:notification, _topic, _payload}
    end

    test "sends one message per publish", %{server: server} do
      assert Subscriptions.publish(server, "news", :first) == :ok
      assert Subscriptions.publish(server, "news", :second) == :ok

      assert_receive {:notification, "news", :first}
      assert_receive {:notification, "news", :second}
      refute_receive {:notification, "news", _payload}, 50
    end
  end

  describe "publish/3 to an email subscriber" do
    setup %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      :ok
    end

    test "mails the address with the topic in the subject", %{server: server} do
      assert Subscriptions.publish(server, "news", :ignored) == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not mail the address for other topics", %{server: server} do
      assert Subscriptions.publish(server, "sports", :goal) == :ok

      refute_receive {:delivered, _to, _subject}, 50
    end
  end

  describe "publish/3 to pid and email subscribers of one topic" do
    test "notifies each of them", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  describe "publish/3 on a topic without subscribers" do
    test "sends nothing", %{server: server} do
      assert Subscriptions.publish(server, "empty", :update) == :ok

      assert Subscriptions.subscribers(server, "empty") == []
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_and_exit]

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of those topics", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []

      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "keeps the server running", %{server: server} do
      assert Process.alive?(server)
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when an email subscriber and a process subscribe to one topic and the process exits" do
    test "keeps the email address subscribed", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      subscriber = start_supervised!({Agent, fn -> :ok end})
      assert Subscriptions.subscribe(server, "news", subscriber) == :ok

      stop_and_wait(subscriber)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    subscriber = start_supervised!({Agent, fn -> :ok end})
    assert Subscriptions.subscribe(server, "news", subscriber) == :ok
    assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

    stop_and_wait(subscriber)
    :ok
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    :ok = Agent.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
