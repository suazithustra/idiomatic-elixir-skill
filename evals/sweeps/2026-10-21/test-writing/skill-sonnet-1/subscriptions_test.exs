ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc """
  Reports each delivery to the processes registered under the name of the calling
  `Notify.Subscriptions` server, so async tests can each watch their own server.
  """

  @behaviour Notify.Mailer

  @registry Notify.TestMailer.Registry

  @doc "Registers the calling process to receive deliveries made by the server called `server_name`."
  def watch(server_name) do
    {:ok, _owner} = Registry.register(@registry, server_name, nil)
    :ok
  end

  @impl true
  def deliver(to, subject) do
    {:registered_name, server_name} = Process.info(self(), :registered_name)

    Registry.dispatch(@registry, server_name, fn watchers ->
      for {watcher, _value} <- watchers, do: send(watcher, {:delivered, to, subject})
    end)

    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.TestMailer

  setup_all do
    start_supervised!({Registry, keys: :duplicate, name: Notify.TestMailer.Registry})
    :ok
  end

  setup do
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    TestMailer.watch(name)

    %{server: name}
  end

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)

      assert {:error, {%KeyError{key: :mailer}, _stacktrace}} =
               Subscriptions.start_link(name: :subscriptions_without_mailer)
    end
  end

  describe "subscribe/3" do
    test "returns :ok for a pid and for an email address", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ana@example.com")
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "ana@example.com")
      Subscriptions.subscribe(server, "sports", "bo@example.com")

      assert ["ana@example.com"] == Subscriptions.subscribers(server, "news")
      assert ["bo@example.com"] == Subscriptions.subscribers(server, "sports")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert [] == Subscriptions.subscribers(server, "empty")
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "last@example.com")

      assert ["last@example.com", self(), "first@example.com"] ==
               Subscriptions.subscribers(server, "news")
    end
  end

  describe "publish/3" do
    test "sends a notification message to a subscribed pid", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{headline: "Hi"})

      assert_receive {:notification, "news", %{headline: "Hi"}}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      Subscriptions.subscribe(server, "news", "ana@example.com")

      Subscriptions.publish(server, "news", %{headline: "Hi"})

      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ana@example.com")

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "bo@example.com")

      Subscriptions.publish(server, "news", :update)
      # A synchronous call returns only after the earlier publish was handled.
      Subscriptions.subscribers(server, "news")

      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "empty", :update)

      assert [] == Subscriptions.subscribers(server, "empty")
      refute_received {:notification, _topic, _payload}
      refute_received {:delivered, _to, _subject}
    end

    test "notifies a pid once per subscription", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:notification, "news", :update}
      refute_receive {:notification, "news", :update}, 50
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the topic", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      assert [^subscriber] = Subscriptions.subscribers(server, "news")

      stop_and_wait(subscriber)

      assert [] == Subscriptions.subscribers(server, "news")
    end

    test "removes it from every topic it was subscribed to", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "sports", subscriber)

      stop_and_wait(subscriber)

      assert [] == Subscriptions.subscribers(server, "news")
      assert [] == Subscriptions.subscribers(server, "sports")
    end

    test "removes it when it crashes", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      assert [] == Subscriptions.subscribers(server, "news")
    end

    test "keeps other pids and email subscribers", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", "ana@example.com")
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", self())

      stop_and_wait(subscriber)

      assert [self(), "ana@example.com"] == Subscriptions.subscribers(server, "news")
    end

    test "stops notifying it but still notifies the others", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "ana@example.com")

      stop_and_wait(subscriber)
      Subscriptions.publish(server, "news", :update)

      assert_receive {:notification, "news", :update}
      assert_receive {:delivered, "ana@example.com", "New on news"}
      assert Process.whereis(server) |> Process.alive?()
    end

    test "removes a pid subscribed twice after it exits", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "news", subscriber)
      Subscriptions.subscribe(server, "news", subscriber)

      stop_and_wait(subscriber)

      assert [] == Subscriptions.subscribers(server, "news")
    end
  end

  defp start_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
