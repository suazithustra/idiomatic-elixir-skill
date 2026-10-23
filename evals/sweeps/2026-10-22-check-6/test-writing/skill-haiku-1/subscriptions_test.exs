ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the Subscriptions server, so the server's registered name is the
  # test's key in the registry.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(Notify.SubscriptionsTest.Registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  setup_all do
    start_supervised!({Registry, keys: :unique, name: Notify.SubscriptionsTest.Registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.SubscriptionsTest.Registry, name, nil)

    %{
      server:
        start_supervised!(
          {Subscriptions, mailer: Notify.SubscriptionsTest.TestMailer, name: name}
        )
    }
  end

  describe "subscribe/3" do
    test "adds the calling process to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ada@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification tuple to a subscribed process", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", :headline) == :ok
      assert_receive {:notification, "news", :headline}
    end

    test "mails the topic in the subject to a subscribed email address", %{server: server} do
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :headline)
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "notifies process and email subscribers of the topic in one publish", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")

      Subscriptions.publish(server, "news", :headline)
      assert_receive {:notification, "news", :headline}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())

      Subscriptions.publish(server, "news", :headline)
      Subscriptions.publish(server, "sports", :goal)

      # Casts are handled in order, so the sports notification means the news
      # publish was already handled.
      assert_receive {:notification, "sports", :goal}
      refute_received {:notification, "news", _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns the subscribers of the given topic only", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "returns the subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ada@example.com")
      Subscriptions.subscribe(server, "news", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", "ada@example.com", self()]
    end
  end

  describe "when a subscribed process exits" do
    setup :subscribe_and_exit

    test "removes the process from every topic it subscribed to", %{
      server: server,
      exited: exited
    } do
      refute exited in Subscriptions.subscribers(server, "news")
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end

    test "still notifies the remaining subscribers", %{server: server} do
      Subscriptions.publish(server, "news", :headline)

      assert_receive {:notification, "news", :headline}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  defp subscribe_and_exit(%{server: server}) do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Subscriptions.subscribe(server, "news", self())
    :ok = Subscriptions.subscribe(server, "news", pid)
    :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
    :ok = Subscriptions.subscribe(server, "sports", pid)

    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    %{exited: pid}
  end
end
