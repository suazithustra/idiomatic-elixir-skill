ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    test_pid = Application.fetch_env!(:notify, :test_pid)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  # The mailer has no state argument, so it finds the test process through the
  # application environment, which is global.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  setup context do
    Application.put_env(:notify, :test_pid, self())
    on_exit(fn -> Application.delete_env(:notify, :test_pid) end)

    server = start_supervised!({Subscriptions, mailer: Mailer, name: context.test})
    %{server: server}
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns no subscribers for an unknown topic", %{server: server} do
      assert [] = Subscriptions.subscribers(server, "news")
    end

    test "lists subscribers most recent first", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      pid = self()
      assert ["b@example.com", ^pid, "a@example.com"] = Subscriptions.subscribers(server, "news")
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "sports", "b@example.com")

      assert ["a@example.com"] = Subscriptions.subscribers(server, "news")
      assert ["b@example.com"] = Subscriptions.subscribers(server, "sports")
    end

    test "works through the registered name", %{server: server} do
      name = Process.info(server, :registered_name) |> elem(1)
      Subscriptions.subscribe(name, "news", "a@example.com")

      assert ["a@example.com"] = Subscriptions.subscribers(name, "news")
    end
  end

  describe "publish/3" do
    test "sends process subscribers a notification message", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "a@example.com")

      assert :ok = Subscriptions.publish(server, "news", :ignored)

      assert_receive {:delivered, "a@example.com", "New on news"}
      refute_receive {:notification, _topic, _payload}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "a@example.com")
      Subscriptions.subscribe(server, "news", "b@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "a@example.com")

      Subscriptions.publish(server, "news", :hello)
      :sys.get_state(server)

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :hello)
      :sys.get_state(server)

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from the topic", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "a@example.com")

      stop_subscriber(subscriber)

      assert ["a@example.com"] = Subscriptions.subscribers(server, "news")
    end

    test "it is removed from every topic it joined", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)

      stop_subscriber(subscriber)

      assert [] = Subscriptions.subscribers(server, "news")
      assert [] = Subscriptions.subscribers(server, "sports")
    end

    test "other process subscribers stay subscribed", %{server: server} do
      leaving = start_subscriber()
      staying = start_subscriber()
      Subscriptions.subscribe(server, "news", leaving)
      Subscriptions.subscribe(server, "news", staying)

      stop_subscriber(leaving)

      assert [^staying] = Subscriptions.subscribers(server, "news")
    end

    test "publishing still reaches the remaining subscribers", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", "a@example.com")

      stop_subscriber(subscriber)
      Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "a@example.com", "New on news"}
      assert Process.alive?(server)
    end

    test "a crashing subscriber is removed too", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      ref = Process.monitor(subscriber)

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert [] = Subscriptions.subscribers(server, "news")
    end
  end

  defp start_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # The server monitors the subscriber too, so once the test has seen the
  # :DOWN message the server's own :DOWN message is already on its way.
  defp stop_subscriber(subscriber) do
    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
  end
end
