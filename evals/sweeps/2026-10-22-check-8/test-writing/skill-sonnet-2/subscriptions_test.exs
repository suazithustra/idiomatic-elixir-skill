ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false

  @behaviour Notify.Mailer

  @registry __MODULE__.Registry

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

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop(pid, :normal) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp stop(pid, :kill) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  describe "start_link/1" do
    test "fails when no mailer is given", context do
      name = Module.concat(context.module, "#{context.test} without mailer")

      spec = Supervisor.child_spec({Subscriptions, name: name}, id: :without_mailer)

      assert {:error, {{%KeyError{key: :mailer}, _stacktrace}, _spec}} = start_supervised(spec)
    end
  end

  describe "subscribe/3" do
    test "returns :ok for a pid", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "adds an email address to the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps the topics apart", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["bob@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", self(), "ann@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not send the payload to an email subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      :ok = Subscriptions.publish(server, "news", :secret)

      assert_receive {:delivered, "ann@example.com", subject}
      refute subject =~ "secret"
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "notifies every pid subscriber", %{server: server} do
      test_pid = self()

      relay =
        spawn(fn ->
          receive do
            message -> send(test_pid, {:relayed, message})
          end
        end)

      :ok = Subscriptions.subscribe(server, "news", relay)
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:relayed, {:notification, "news", :updated}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "bob@example.com")

      :ok = Subscriptions.publish(server, "news", :updated)
      _ = Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :updated)
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "notifies a subscriber once per subscription", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:notification, "news", :updated}
      refute_receive {:notification, "news", :updated}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "sports", subscriber)

      %{subscriber: subscriber}
    end

    test "removes the process from every topic", %{server: server, subscriber: subscriber} do
      stop(subscriber, :kill)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes the process after a normal exit", %{server: server, subscriber: subscriber} do
      stop(subscriber, :normal)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "keeps the email subscribers notified", %{server: server, subscriber: subscriber} do
      stop(subscriber, :kill)

      :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "keeps the server running", %{server: server, subscriber: subscriber} do
      stop(subscriber, :kill)

      assert Process.alive?(server)
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "leaves other pid subscribers in place", %{server: server, subscriber: subscriber} do
      survivor = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", survivor)

      stop(subscriber, :kill)

      assert Subscriptions.subscribers(server, "news") == [survivor, "ann@example.com"]
    end
  end
end
