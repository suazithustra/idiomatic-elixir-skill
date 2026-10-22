ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @moduledoc """
    Forwards each delivery to the test process registered under the calling
    server's pid, so concurrent tests each see only their own emails.
    """
    @behaviour Notify.Mailer

    @impl true
    def deliver(to, subject) do
      for {test_pid, _} <- Registry.lookup(Notify.SubscriptionsTest.Inboxes, self()) do
        send(test_pid, {:delivered, to, subject})
      end

      :ok
    end
  end

  setup_all do
    start_supervised!({Registry, keys: :duplicate, name: __MODULE__.Inboxes})
    :ok
  end

  setup do
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: nil})
    {:ok, _} = Registry.register(__MODULE__.Inboxes, server, nil)
    %{server: server}
  end

  # A process that stays alive until told to stop.
  defp start_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Waits for the server to handle everything sent to it before this call.
  defp sync(server), do: :sys.get_state(server)

  describe "start_link/1" do
    test "registers under Notify.Subscriptions by default" do
      pid = start_supervised!({Subscriptions, mailer: TestMailer}, id: :default_name)
      assert Process.whereis(Subscriptions) == pid
      assert Subscriptions.subscribe("news", self()) == :ok
      assert Subscriptions.subscribers("news") == [self()]
    end

    test "requires a :mailer" do
      Process.flag(:trap_exit, true)
      assert {:error, {%KeyError{key: :mailer}, _}} = Subscriptions.start_link(name: nil)
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "a topic with no subscribers has none", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "returns pid and email subscribers, most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "a@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "b@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") ==
               ["b@example.com", "a@example.com", self()]
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["b@example.com"]
    end
  end

  describe "publish/3" do
    test "sends a notification to subscribed processes", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails subscribed email addresses with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "notifies processes and emails on the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "only notifies subscribers of the published topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "a@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)
      sync(server)

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "with no subscribers does nothing", %{server: server} do
      assert Subscriptions.publish(server, "news", :hello) == :ok
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from every topic it subscribed to", %{server: server} do
      subscriber = start_subscriber()
      ref = Process.monitor(subscriber)
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "sports", subscriber)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}

      assert Subscriptions.subscribers(server, "news") == ["a@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "it is removed when it crashes", %{server: server} do
      subscriber = start_subscriber()
      ref = Process.monitor(subscriber)
      :ok = Subscriptions.subscribe(server, "news", subscriber)

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "other subscribed processes are kept", %{server: server} do
      subscriber = start_subscriber()
      ref = Process.monitor(subscriber)
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _}

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "a process that is already dead is removed right away", %{server: server} do
      subscriber = start_subscriber()
      ref = Process.monitor(subscriber)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _}

      :ok = Subscriptions.subscribe(server, "news", subscriber)
      sync(server)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "publishing afterwards still reaches the remaining subscribers", %{server: server} do
      subscriber = start_subscriber()
      ref = Process.monitor(subscriber)
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "news", self())

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _}

      :ok = Subscriptions.publish(server, "news", :after_exit)
      assert_receive {:notification, "news", :after_exit}
      assert Process.alive?(server)
    end
  end
end
