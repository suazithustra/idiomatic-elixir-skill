ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # deliver/2 runs inside the subscriptions server, not the test process, so
  # each test registers the addresses it wants to receive mail for.
  @registry __MODULE__.Registry

  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc "Sends mail delivered to `address` to the calling process as `{:mail, to, subject}`."
  def capture_mail_to(address) do
    {:ok, _owner} = Registry.register(@registry, address, nil)
    :ok
  end

  @impl true
  def deliver(to, subject) do
    [{test_pid, nil}] = Registry.lookup(@registry, to)
    send(test_pid, {:mail, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions
  alias Notify.TestMailer

  setup_all do
    start_supervised!(TestMailer)
    :ok
  end

  setup %{test: test} do
    %{server: start_supervised!({Subscriptions, mailer: TestMailer, name: test})}
  end

  describe "subscribe/3" do
    test "adds a process to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "orders", self()) == :ok
      assert Subscriptions.subscribers(server, "orders") == [self()]
    end

    test "adds an email address to the topic's subscribers", %{server: server} do
      assert Subscriptions.subscribe(server, "orders", "ana@example.com") == :ok
      assert Subscriptions.subscribers(server, "orders") == ["ana@example.com"]
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "orders") == []
    end

    test "returns the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "orders", "ana@example.com")
      Subscriptions.subscribe(server, "orders", self())
      Subscriptions.subscribe(server, "orders", "ben@example.com")

      assert Subscriptions.subscribers(server, "orders") ==
               ["ben@example.com", self(), "ana@example.com"]
    end

    test "returns only the subscribers of the given topic", %{server: server} do
      Subscriptions.subscribe(server, "orders", "ana@example.com")
      Subscriptions.subscribe(server, "invoices", "ben@example.com")

      assert Subscriptions.subscribers(server, "orders") == ["ana@example.com"]
    end
  end

  describe "publish/3" do
    test "sends the topic and payload to subscribed processes", %{server: server} do
      Subscriptions.subscribe(server, "orders", self())

      assert Subscriptions.publish(server, "orders", %{id: 42}) == :ok
      assert_receive {:notification, "orders", %{id: 42}}
    end

    test "mails subscribed email addresses", %{server: server} do
      TestMailer.capture_mail_to("ana@example.com")
      Subscriptions.subscribe(server, "orders", "ana@example.com")

      Subscriptions.publish(server, "orders", %{id: 42})

      assert_receive {:mail, "ana@example.com", "New on orders"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      TestMailer.capture_mail_to("ana@example.com")
      Subscriptions.subscribe(server, "invoices", self())
      Subscriptions.subscribe(server, "invoices", "ana@example.com")

      Subscriptions.publish(server, "orders", %{id: 42})
      # publish/3 is a cast. The server handles messages in order, so once this
      # call returns, any notification it sent is already in the mailbox.
      Subscriptions.subscribers(server, "orders")

      refute_received {:notification, _topic, _payload}
      refute_received {:mail, _to, _subject}
    end
  end

  describe "when a subscribed process exits" do
    test "removes it from the topic's subscribers", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "orders", "ana@example.com")
      Subscriptions.subscribe(server, "orders", subscriber)

      stop_subscriber(subscriber)

      assert Subscriptions.subscribers(server, "orders") == ["ana@example.com"]
    end

    test "removes it from every topic", %{server: server} do
      subscriber = start_subscriber()
      Subscriptions.subscribe(server, "orders", subscriber)
      Subscriptions.subscribe(server, "invoices", subscriber)

      stop_subscriber(subscriber)

      assert Subscriptions.subscribers(server, "orders") == []
      assert Subscriptions.subscribers(server, "invoices") == []
    end
  end

  defp start_subscriber do
    start_supervised!(
      {Task,
       fn ->
         receive do
           :stop -> :ok
         end
       end}
    )
  end

  defp stop_subscriber(subscriber) do
    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, ^subscriber, :normal}
  end
end
