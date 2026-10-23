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

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns pids and email addresses subscribed to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "b@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "c@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") ==
               ["c@example.com", "b@example.com", "a@example.com"]
    end

    test "keeps subscribers of different topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "b@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3 to a process subscriber" do
    test "sends the topic and payload to the pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify a subscriber of another topic", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok
      # a synchronous call returns after the publish cast was handled
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}
    end

    test "notifies every pid subscribed to the topic", %{server: server} do
      test_pid = self()

      other =
        spawn_link(fn ->
          receive do
            {:notification, _topic, _payload} = message -> send(test_pid, {:other, message})
          end
        end)

      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", other) == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:notification, "news", :update}
      assert_receive {:other, {:notification, "news", :update}}
    end
  end

  describe "publish/3 to an email subscriber" do
    test "mails the address with a subject naming the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "mails every address subscribed to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "bob@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "mails nobody when the topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", "ann@example.com") == :ok

      assert Subscriptions.publish(server, "news", :update) == :ok
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process has exited" do
    setup %{server: server} do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(subscriber)

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      %{subscriber: subscriber}
    end

    test "subscribers/2 no longer lists it on any topic", %{server: server} do
      # the server handles its own :DOWN message before it replies to a later call
      :sys.get_state(server)

      assert Subscriptions.subscribers(server, "sports") == []
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "publish/3 still mails the remaining email subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :update) == :ok

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert Process.alive?(server)
    end
  end
end
