ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  # Runs inside the Subscriptions server, so the server's registered name
  # is the key the test registered under.
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

  alias Notify.{Subscriptions, TestMailer}

  setup_all do
    start_supervised!({Registry, keys: :unique, name: TestMailer.Registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: server}
  end

  describe "subscribe/3" do
    test "adds the pid to the subscribers of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "news", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "grace@example.com",
               "ada@example.com"
             ]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "sport") == []
    end
  end

  describe "publish/3" do
    test "sends the notification to a subscribed pid", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{headline: "Launch"})
      assert_receive {:notification, "news", %{headline: "Launch"}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", "Launch")

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", "Launch")

      assert_receive {:notification, "news", "Launch"}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "sport", "Final score")
      # publish/3 is a cast; the server handles it before replying to this call
      _ = :sys.get_state(server)

      refute_received {:notification, _, _}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the subscribers of its topic", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)

      exit_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes a killed subscriber", %{server: server} do
      pid = spawn_subscriber()
      ref = Process.monitor(pid)
      :ok = Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the exited subscriber from every topic it joined", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)

      exit_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      exit_subscriber(pid)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "still mails the remaining subscribers after one exits", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      exit_subscriber(pid)
      :ok = Subscriptions.publish(server, "news", "Launch")

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "drops a pid that had already exited when it subscribed", %{server: server} do
      pid = spawn_subscriber()
      exit_subscriber(pid)

      :ok = Subscriptions.subscribe(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  defp spawn_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp exit_subscriber(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
