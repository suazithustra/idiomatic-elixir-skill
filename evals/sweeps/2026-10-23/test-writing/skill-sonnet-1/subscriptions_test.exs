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
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps the same subscriber on several topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", self()) == :ok

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sports") == [self()]
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

      assert Subscriptions.subscribers(server, "news") ==
               ["last@example.com", self(), "first@example.com"]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "grace@example.com") == :ok

      assert Subscriptions.subscribers(server, "sports") == ["grace@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a pid subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{headline: "Hello"}) == :ok

      assert_receive {:notification, "news", %{headline: "Hello"}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{headline: "Hello"}) == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "grace@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      # the call is answered after the publish cast was handled
      assert Subscriptions.subscribers(server, "news") == []

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert Subscriptions.subscribers(server, "news") == []
      refute_received _message
    end
  end

  describe "when a subscribed process has exited" do
    setup %{server: server} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sports", pid) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      %{pid: pid}
    end

    test "removes it from every topic", %{server: server, pid: pid} do
      refute pid in Subscriptions.subscribers(server, "news")
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == [self(), "ada@example.com"]
    end

    test "still notifies the remaining subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  describe "when an email subscriber is the only subscriber and a process exits elsewhere" do
    test "keeps the email subscriber", %{server: server} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "other", pid) == :ok

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end
end
