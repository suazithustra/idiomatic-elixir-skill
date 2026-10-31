ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  # deliver/2 runs inside the server, so its registered name is the key the
  # test process registered itself under.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.TestMailer.Registry, server)
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
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == ["ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "news", "Elixir 1.20 released")
      assert_receive {:notification, "news", "Elixir 1.20 released"}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      Subscriptions.publish(server, "news", "Elixir 1.20 released")
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      Subscriptions.publish(server, "news", "Elixir 1.20 released")
      assert_receive {:notification, "news", "Elixir 1.20 released"}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not notify the subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      Subscriptions.publish(server, "sports", "Cup final tonight")
      Subscriptions.publish(server, "news", "Elixir 1.20 released")
      assert_receive {:notification, "news", "Elixir 1.20 released"}
      refute_received {:notification, "sports", _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end
  end

  describe "when a subscribed process exits" do
    setup :subscribe_a_process_that_exits

    test "removes it from the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "removes it from every topic it subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", "Elixir 1.20 released")
      assert_receive {:notification, "news", "Elixir 1.20 released"}
    end
  end

  defp subscribe_a_process_that_exits(%{server: server}) do
    reader = start_supervised!({Agent, fn -> nil end})
    :ok = Subscriptions.subscribe(server, "news", self())
    :ok = Subscriptions.subscribe(server, "news", reader)
    :ok = Subscriptions.subscribe(server, "sports", reader)
    :ok = stop_supervised!(Agent)
    :ok
  end
end
