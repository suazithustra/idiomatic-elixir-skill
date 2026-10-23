ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Runs inside the Notify.Subscriptions server, so it reports each delivery to the
  # test process registered under this module's name. Mail to "bounce@example.com" fails.
  @impl true
  def deliver(to, subject) do
    send(__MODULE__, {:delivered, to, subject})
    if to == "bounce@example.com", do: {:error, :rejected}, else: :ok
  end
end

defmodule Notify.SubscriptionsTest do
  # Not async: the server and the mailer's test process use fixed registered names.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    Process.register(self(), Notify.TestMailer)
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer})
    %{server: server}
  end

  describe "subscribe/3" do
    test "adds a pid to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "adds an email address to the topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ann@example.com") == :ok
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
    end

    test "leaves other topics untouched", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "news", "bob@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["bob@example.com", "ann@example.com", self()]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to subscribed processes", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.publish(server, "news", %{id: 1}) == :ok
      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails every subscribed address through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "news", "bob@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert_receive {:delivered, "bob@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", "ann@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})
      wait_for_publish(server)

      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end

    test "keeps notifying subscribers after a failed delivery", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      # Subscribed last, so notified first.
      :ok = Subscriptions.subscribe(server, "news", "bounce@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "bounce@example.com", "New on news"}
      assert_receive {:notification, "news", %{id: 1}}
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from every topic it subscribed to", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "sports", subscriber)

      send(subscriber, :stop)

      assert_removed(server, "news", subscriber)
      assert_removed(server, "sports", subscriber)
    end

    test "the other subscribers of its topics are kept", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      send(subscriber, :stop)
      assert_removed(server, "news", subscriber)

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "it is removed whether it exits normally or is killed", %{server: server} do
      finished = start_subscriber()
      killed = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", finished)
      :ok = Subscriptions.subscribe(server, "news", killed)

      send(finished, :stop)
      Process.exit(killed, :kill)

      assert_removed(server, "news", finished)
      assert_removed(server, "news", killed)
    end

    test "it is removed even if it subscribed to the topic twice", %{server: server} do
      subscriber = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", subscriber)
      :ok = Subscriptions.subscribe(server, "news", subscriber)

      send(subscriber, :stop)

      assert_removed(server, "news", subscriber)
    end
  end

  describe "without a server argument" do
    test "the functions use the server registered as Notify.Subscriptions", %{server: server} do
      assert Process.whereis(Notify.Subscriptions) == server

      :ok = Subscriptions.subscribe("news", self())
      assert Subscriptions.subscribers("news") == [self()]

      :ok = Subscriptions.publish("news", %{id: 1})
      assert_receive {:notification, "news", %{id: 1}}
    end
  end

  defp start_subscriber do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # publish/3 is a cast. A call made after it is handled after it, so every
  # notification has been sent by the time this returns.
  defp wait_for_publish(server), do: :sys.get_state(server)

  # The server learns about an exit from its own :DOWN message, which is not ordered
  # with our calls, so poll until it has been handled.
  defp assert_removed(server, topic, pid, attempts \\ 50) do
    cond do
      pid not in Subscriptions.subscribers(server, topic) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        assert_removed(server, topic, pid, attempts - 1)

      true ->
        flunk("#{inspect(pid)} is still subscribed to #{inspect(topic)}")
    end
  end
end
