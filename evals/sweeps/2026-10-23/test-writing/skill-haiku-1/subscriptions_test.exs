ExUnit.start()

defmodule TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # Runs inside the server, so the server's registered name finds the test process.
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(TestMailer.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

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
    test "returns :ok for a pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
    end

    test "adds a pid to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "does not add the subscriber to other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "first@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "second@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end
  end

  describe "publish/3 to a pid subscriber" do
    test "sends the topic and payload to the pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
    end

    test "does not notify a pid subscribed to another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "sports", :final) == :ok

      # publish/3 is a cast; this call returns after the server handled it.
      assert Subscriptions.subscribers(server, "sports") == []
      refute_received {:notification, _topic, _payload}
    end

    test "does not mail a pid subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      refute_received {:delivered, _to, _subject}
    end
  end

  describe "publish/3 to an email subscriber" do
    test "delivers an email whose subject names the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "does not send a pid notification to an email subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:delivered, "reader@example.com", _subject}
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "publish/3 to a mix of subscribers" do
    test "notifies a pid and mails an email address on the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok
      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "reader@example.com", "New on news"}
    end
  end

  describe "publish/3 to a topic with no subscribers" do
    test "leaves the server running", %{server: server} do
      assert Subscriptions.publish(server, "empty", :updated) == :ok
      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "when a pid subscriber exits" do
    test "removes it from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sports", pid) == :ok

      exit_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the email subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", "reader@example.com") == :ok

      exit_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "still notifies the live subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      exit_and_wait(pid)

      assert Subscriptions.publish(server, "news", :updated) == :ok
      assert_receive {:notification, "news", :updated}
    end
  end

  describe "start_link/1" do
    test "fails to start without a :mailer", context do
      name = Module.concat(context.module, context.test)
      assert {:error, _reason} = start_supervised({Subscriptions, name: name})
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end

  defp exit_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
