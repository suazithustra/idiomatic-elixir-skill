ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

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

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.TestMailer.Registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, name, nil)
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})
    %{server: server}
  end

  describe "subscribe/3" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "delivers publications on the topic to a process subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails publications on the topic to an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not deliver publications on other topics", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "sports", :goal)
      # publish/3 is a cast; a synchronous call makes the refute check a handled publication
      :sys.get_state(server)

      refute_receive {:notification, _topic, _payload}
    end
  end

  describe "publish/3" do
    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "grace@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "leaves the server running for a topic without subscribers", %{server: server} do
      Subscriptions.publish(server, "empty", :hello)

      assert Subscriptions.subscribers(server, "empty") == []
    end
  end

  describe "subscribers/2" do
    test "returns the subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "sports", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end

    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from every topic it subscribed to", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      exit_subscriber(pid, :normal)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes it when it exits with an error", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      exit_subscriber(pid, {:error, :boom})

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      exit_subscriber(pid, :normal)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end

    test "still notifies the remaining subscribers", %{server: server} do
      pid = spawn_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())
      exit_subscriber(pid, :normal)

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
    end
  end

  # Starts a process that exits with the reason sent to it, so tests choose how it exits.
  defp spawn_subscriber do
    pid =
      spawn(fn ->
        receive do
          {:exit, reason} -> exit(reason)
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp exit_subscriber(pid, reason) do
    ref = Process.monitor(pid)
    send(pid, {:exit, reason})
    assert_receive {:DOWN, ^ref, :process, ^pid, ^reason}
  end
end
