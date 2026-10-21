ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  @inboxes __MODULE__.Inboxes

  defmodule Mailer do
    @moduledoc false
    @behaviour Notify.Mailer

    # Delivers to whichever test process registered the address in the inboxes registry.
    @impl true
    def deliver(to, subject) do
      for {pid, _} <- Registry.lookup(Notify.SubscriptionsTest.Inboxes, to) do
        send(pid, {:email, to, subject})
      end

      :ok
    end
  end

  defmodule FailingMailer do
    @moduledoc false
    @behaviour Notify.Mailer

    @impl true
    def deliver(_to, _subject), do: {:error, :unavailable}
  end

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @inboxes})
    :ok
  end

  describe "subscribe/3 and subscribers/2" do
    setup :start_server

    test "returns no subscribers for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists process and email subscribers, most recent first", %{server: server} do
      pid = spawn_subscriber()

      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", pid]
    end

    test "keeps each topic's subscribers separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "sports", "grace@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["grace@example.com"]
    end
  end

  describe "publish/3" do
    setup :start_server

    test "sends the payload to subscribed processes", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails email subscribers with the topic in the subject", %{server: server} do
      address = inbox("ada@example.com")
      :ok = Subscriptions.subscribe(server, "news", address)

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:email, "ada@example.com", "New on news"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      address = inbox("ada@example.com")
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", address)

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:email, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      address = inbox("ada@example.com")
      :ok = Subscriptions.subscribe(server, "sports", self())
      :ok = Subscriptions.subscribe(server, "sports", address)

      :ok = Subscriptions.publish(server, "news", :hello)

      # The server handles messages in order, so once this call returns the publish is done.
      Subscriptions.subscribers(server, "sports")
      refute_received {:notification, _, _}
      refute_received {:email, _, _}
    end

    @tag mailer: FailingMailer
    test "still notifies processes when an email delivery fails", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]
    end
  end

  describe "when a subscribed process exits" do
    setup :start_server

    test "it is removed from every topic, and other subscribers stay", %{server: server} do
      pid = spawn_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      :ok = Subscriptions.subscribe(server, "sports", pid)

      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
      assert Subscriptions.subscribers(server, "sports") == []
    end
  end

  describe "without an explicit server" do
    test "uses the server registered as Notify.Subscriptions" do
      start_supervised!({Subscriptions, mailer: Mailer})

      :ok = Subscriptions.subscribe("news", self())
      :ok = Subscriptions.publish("news", :hello)

      assert_receive {:notification, "news", :hello}
      assert Subscriptions.subscribers("news") == [self()]
    end
  end

  defp start_server(context) do
    mailer = Map.get(context, :mailer, Mailer)
    %{server: start_supervised!({Subscriptions, mailer: mailer, name: context.test})}
  end

  defp spawn_subscriber do
    spawn_link(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp inbox(address) do
    {:ok, _} = Registry.register(@inboxes, address, nil)
    address
  end
end
