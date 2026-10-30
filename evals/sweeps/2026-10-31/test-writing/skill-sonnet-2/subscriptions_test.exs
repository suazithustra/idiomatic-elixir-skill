ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry Notify.SubscriptionsTest.MailerRegistry

  def registry, do: @registry

  # deliver/2 runs inside the server, so its registered name is the test's key
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

  describe "start_link/1" do
    test "fails when the mailer option is missing", context do
      name = Module.concat(context.module, "#{context.test} without mailer")

      spec = Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _child}} = start_supervised(spec)
    end
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

    test "keeps topics apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", "grace@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["grace@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "grace@example.com") == :ok

      expected = ["grace@example.com", self(), "ada@example.com"]
      assert Subscriptions.subscribers(server, "news") == expected
    end
  end

  describe "publish/3" do
    test "sends a notification to a subscribed pid", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails a subscribed email address", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "grace@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sports", self()) == :ok
      assert Subscriptions.subscribe(server, "sports", "ada@example.com") == :ok

      assert Subscriptions.publish(server, "news", :updated) == :ok
      # a call is handled after the earlier publish cast
      assert Subscriptions.subscribers(server, "news") == []

      refute_receive {:notification, _topic, _payload}, 50
      refute_receive {:delivered, _to, _subject}, 50
    end

    test "sends one notification per publish", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", :first) == :ok
      assert Subscriptions.publish(server, "news", :second) == :ok

      assert_receive {:notification, "news", :first}
      assert_receive {:notification, "news", :second}
      refute_receive {:notification, "news", _payload}, 50
    end
  end

  describe "when a subscribed process has exited" do
    setup %{server: server} do
      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      assert Subscriptions.subscribe(server, "news", subscriber) == :ok
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribe(server, "sports", subscriber) == :ok

      %{subscriber: subscriber}
    end

    test "removes it from every topic", %{server: server, subscriber: subscriber} do
      stop(subscriber, :killed)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes it after a normal exit", %{server: server, subscriber: subscriber} do
      stop(subscriber, :normal)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "keeps notifying the remaining subscribers", %{server: server, subscriber: subscriber} do
      stop(subscriber, :killed)

      assert Subscriptions.publish(server, "news", :updated) == :ok

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "keeps the server running", %{server: server, subscriber: subscriber} do
      stop(subscriber, :killed)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Process.alive?(server)
    end
  end

  defp stop(pid, :normal) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp stop(pid, :killed) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
