ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(Application.fetch_env!(:notify, :test_pid), {:delivered, to, subject})
    Application.get_env(:notify, :mailer_result, :ok)
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    Application.put_env(:notify, :test_pid, self())

    on_exit(fn ->
      Application.delete_env(:notify, :test_pid)
      Application.delete_env(:notify, :mailer_result)
    end)

    server = :"subscriptions_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: server})

    %{server: server, pid: pid}
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns the subscribers of a topic, most recent first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.subscribers(server, "news") == ["ann@example.com", self()]
    end

    test "keeps topics separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")

      assert Subscriptions.subscribers(server, "sport") == []
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
    end

    test "notifies every subscriber of the topic", %{server: server} do
      other = spawn_forwarder(self())
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", other)
      :ok = Subscriptions.publish(server, "news", 42)

      assert_receive {:notification, "news", 42}
      assert_receive {:forwarded, ^other, {:notification, "news", 42}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "sport", self())
      :ok = Subscriptions.publish(server, "news", "hello")

      # The call below is handled after the publish cast, so the publish has been processed by now.
      _ = Subscriptions.subscribers(server, "news")

      refute_received {:notification, _, _}
    end

    test "mails each email subscriber with the topic in the subject", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "ann@example.com", "New on news"}
    end

    test "keeps running when the mailer returns an error", %{server: server, pid: pid} do
      Application.put_env(:notify, :mailer_result, {:error, :timeout})

      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "ann@example.com", "New on news"}
      assert Subscriptions.subscribers(server, "news") == ["ann@example.com"]
      assert Process.alive?(pid)
    end
  end

  describe "when a subscribed process exits" do
    test "removes a killed pid subscriber", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      wait_for_subscribers(server, "news", [])
    end

    test "removes a pid subscriber after a normal exit", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)

      send(pid, :stop)

      wait_for_subscribers(server, "news", [])
    end

    test "removes the exited pid from every topic it subscribed to", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)

      Process.exit(pid, :kill)

      wait_for_subscribers(server, "news", [])
      wait_for_subscribers(server, "sport", [])
    end

    test "keeps the other pid subscribers of the topic", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      wait_for_subscribers(server, "news", [self()])

      :ok = Subscriptions.publish(server, "news", "hello")
      assert_receive {:notification, "news", "hello"}
    end

    test "keeps email subscribers", %{server: server} do
      pid = spawn_idle()
      :ok = Subscriptions.subscribe(server, "news", "ann@example.com")
      :ok = Subscriptions.subscribe(server, "news", pid)

      Process.exit(pid, :kill)

      wait_for_subscribers(server, "news", ["ann@example.com"])
    end

    test "removes a pid that was already dead when it subscribed", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      :ok = Subscriptions.subscribe(server, "news", pid)

      wait_for_subscribers(server, "news", [])
    end
  end

  describe "start_link/1" do
    test "registers the server under Notify.Subscriptions by default" do
      {:ok, pid} = Subscriptions.start_link(mailer: Notify.TestMailer)

      assert Process.whereis(Subscriptions) == pid

      :ok = Subscriptions.subscribe("news", self())
      assert Subscriptions.subscribers("news") == [self()]

      GenServer.stop(pid)
    end
  end

  defp spawn_idle do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp spawn_forwarder(parent) do
    spawn(fn ->
      receive do
        msg -> send(parent, {:forwarded, self(), msg})
      end
    end)
  end

  # Exit handling is asynchronous: the server removes a subscriber when it
  # handles the :DOWN message, so poll until the list matches.
  defp wait_for_subscribers(server, topic, expected, attempts \\ 100) do
    current = Subscriptions.subscribers(server, topic)

    cond do
      current == expected ->
        :ok

      attempts == 0 ->
        flunk("expected #{inspect(expected)} on #{topic}, got #{inspect(current)}")

      true ->
        Process.sleep(10)
        wait_for_subscribers(server, topic, expected, attempts - 1)
    end
  end
end
