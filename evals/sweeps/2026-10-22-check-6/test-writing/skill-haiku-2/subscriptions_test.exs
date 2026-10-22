ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so its registered name is the test's key
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, nil}] = Registry.lookup(@registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.TestMailer

  @registry Notify.TestMailer.Registry

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup context do
    name = Module.concat(context.module, context.test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: name}
  end

  describe "subscribe/3" do
    test "adds the pid to the topic's subscribers", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "first@example.com")
      :ok = Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "second@example.com",
               "first@example.com"
             ]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "sport", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sport") == ["ada@example.com"]
    end

    test "removes a pid that had already exited when it subscribed", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      :ok = Subscriptions.subscribe(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3" do
    test "sends the notification to a subscribed pid", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "sport", :goal)
      # The reply to this call comes after the cast is handled, so a notification
      # sent for the cast is already in the mailbox when it returns.
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, "sport", _payload}
    end

    test "mails an email subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies a pid and an email subscriber of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:notification, "news", :launched}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    setup %{server: server} do
      subscriber = spawn_waiting()
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "sport", subscriber)
      :ok = Subscriptions.subscribe(server, "news", self())

      %{subscriber: subscriber}
    end

    test "removes the exited pid from every topic it subscribed to", %{
      server: server,
      subscriber: subscriber
    } do
      exit_and_wait(subscriber)

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other subscribers of the topic and still notifies them", %{
      server: server,
      subscriber: subscriber
    } do
      exit_and_wait(subscriber)

      :ok = Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
    end
  end

  defp spawn_waiting do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp exit_and_wait(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
