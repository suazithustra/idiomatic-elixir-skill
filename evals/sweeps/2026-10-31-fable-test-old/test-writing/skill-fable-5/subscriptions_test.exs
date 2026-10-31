ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  def registry, do: @registry

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
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps the subscriber out of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "publish/3" do
    test "sends the payload to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", %{title: "Elixir 1.20 released"}) == :ok
      assert_receive {:notification, "news", %{title: "Elixir 1.20 released"}}
    end

    test "mails a subscribed address with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.publish(server, "news", %{title: "Elixir 1.20 released"}) == :ok
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :release) == :ok
      assert_receive {:notification, "news", :release}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "leaves subscribers of other topics alone", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.publish(server, "news", :release) == :ok
      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self(), "ada@example.com"]
    end
  end

  describe "when a subscribed process has exited" do
    setup [:subscribe_and_exit]

    test "subscribers/2 no longer lists it on any topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "publish/3 still reaches the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :release) == :ok
      assert_receive {:notification, "news", :release}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    exiting = spawn_link(fn -> receive(do: (:stop -> :ok)) end)
    ref = Process.monitor(exiting)

    assert Subscriptions.subscribe(server, "news", exiting) == :ok
    assert Subscriptions.subscribe(server, "sports", exiting) == :ok
    assert Subscriptions.subscribe(server, "news", self()) == :ok

    send(exiting, :stop)
    assert_receive {:DOWN, ^ref, :process, ^exiting, :normal}
    %{exited: exiting}
  end
end
