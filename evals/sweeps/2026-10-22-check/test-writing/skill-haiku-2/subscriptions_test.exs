ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # Runs inside the server, so the server's registered name is the test's key
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
    %{server: start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})}
  end

  describe "publish/3 to pid subscribers" do
    test "notifies the pid of publishes on its topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:notification, "news", :launched}
    end

    test "does not notify the pid of publishes on other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "sports", :goal)
      :ok = Subscriptions.publish(server, "news", :launched)

      # The server handles casts in order, so a "sports" notification would arrive first
      assert_receive {:notification, "news", :launched}
      refute_received {:notification, "sports", _payload}
    end
  end

  describe "publish/3 to email subscribers" do
    test "mails the address with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "does not mail addresses subscribed to other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "bob@example.com")
      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:delivered, "ann@example.com", "New on news"}
      refute_received {:delivered, "bob@example.com", _subject}
    end

    test "notifies a pid and mails an address subscribed to the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:notification, "news", :launched}
      assert_receive {:delivered, "ann@example.com", "New on news"}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list when the topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers of the topic, most recent first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "leaves out subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end
  end

  describe "when a subscribed pid exits" do
    setup %{server: server} do
      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "sports", subscriber)

      %{subscriber: subscriber}
    end

    test "removes the pid from every topic it subscribed to", %{
      server: server,
      subscriber: subscriber
    } do
      stop(subscriber)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "removes a pid that was killed", %{server: server, subscriber: subscriber} do
      kill(subscriber)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "keeps the other pid subscribers of the topic", %{
      server: server,
      subscriber: subscriber
    } do
      :ok = Subscriptions.subscribe(server, "news", self())
      stop(subscriber)
      :ok = Subscriptions.publish(server, "news", :launched)

      assert Subscriptions.subscribers(server, "news") == [self()]
      assert_receive {:notification, "news", :launched}
    end

    test "keeps the email subscribers of the topic", %{server: server, subscriber: subscriber} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      stop(subscriber)
      :ok = Subscriptions.publish(server, "news", :launched)

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end
  end

  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
