ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    # deliver/2 runs inside the server, so the test is found through the server's name
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

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(Notify.TestMailer.Registry, name, nil)
    %{server: start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})}
  end

  describe "subscribe/3" do
    test "notifies a pid subscriber of publishes on its topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", %{score: 3})

      assert_receive {:notification, "news", %{score: 3}}
    end

    test "does not notify a pid subscriber of publishes on other topics", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "sports", :final)
      sync(server)

      refute_received {:notification, _topic, _payload}
    end
  end

  describe "publish/3" do
    test "notifies every pid and email subscriber of the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert :ok = Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "mails each email subscriber with the topic in the subject", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", "grace@example.com")

      Subscriptions.publish(server, "news", :updated)

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "does not mail email subscribers of other topics", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "sports", "ada@example.com")

      Subscriptions.publish(server, "news", :updated)
      sync(server)

      refute_received {:delivered, _to, _subject}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :updated)

      assert Subscriptions.subscribers(server, "news") == []
      refute_received {:notification, _topic, _payload}
    end
  end

  describe "subscribers/2" do
    test "returns an empty list when the topic has no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists the subscribers of the topic, most recent first", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self(), "ada@example.com"]
    end

    test "leaves out subscribers of other topics", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "sports", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com"]
    end
  end

  describe "when a subscribed process exits" do
    test "removes the process from the topic it subscribed to", %{server: server} do
      {pid, ref} = start_idle_process()
      assert :ok = Subscriptions.subscribe(server, "news", pid)

      stop_process(pid, ref)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process from every topic it subscribed to", %{server: server} do
      {pid, ref} = start_idle_process()
      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert :ok = Subscriptions.subscribe(server, "sports", pid)

      stop_process(pid, ref)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "keeps the other subscribers of the topic and still notifies them", %{server: server} do
      {pid, ref} = start_idle_process()
      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert :ok = Subscriptions.subscribe(server, "news", self())
      assert :ok = Subscriptions.subscribe(server, "news", "ada@example.com")

      stop_process(pid, ref)

      assert Subscriptions.subscribers(server, "news") == ["ada@example.com", self()]

      Subscriptions.publish(server, "news", :updated)

      assert_receive {:notification, "news", :updated}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end
  end

  defp start_idle_process do
    spawn_monitor(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp stop_process(pid, ref) do
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  # The server handles casts in order, so a system call sent after a cast
  # returns only once the cast has been handled and any notification is in the mailbox.
  defp sync(server), do: :sys.get_state(server)
end
