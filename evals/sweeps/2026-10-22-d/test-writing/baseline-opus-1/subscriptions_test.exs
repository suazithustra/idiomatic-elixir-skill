ExUnit.start()

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  alias Notify.Subscriptions

  defmodule TestMailer do
    @moduledoc false
    @behaviour Notify.Mailer

    # The server is started by `start_supervised!/1`, so the test process is
    # the last of its ancestors. Delivering to it keeps tests async-safe.
    @impl true
    def deliver("fail@example.com" = to, subject) do
      send(test_pid(), {:delivered, to, subject})
      {:error, :rejected}
    end

    def deliver(to, subject) do
      send(test_pid(), {:delivered, to, subject})
      :ok
    end

    defp test_pid, do: Process.get(:"$ancestors") |> List.last()
  end

  setup do
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: nil})
    %{server: server}
  end

  defp start_subscriber do
    spawn_link(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Publishing is a cast; a call afterwards guarantees the server has handled it.
  defp sync(server), do: Subscriptions.subscribers(server, "sync")

  describe "start_link/1" do
    test "requires the :mailer option" do
      Process.flag(:trap_exit, true)
      assert {:error, {%KeyError{key: :mailer}, _}} = Subscriptions.start_link(name: nil)
    end

    test "registers under the given name" do
      name = :"#{inspect(__MODULE__)}.named"
      start_supervised!({Subscriptions, mailer: TestMailer, name: name}, id: :named)

      assert :ok = Subscriptions.subscribe(name, "news", "a@example.com")
      assert Subscriptions.subscribers(name, "news") == ["a@example.com"]
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns an empty list for a topic without subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "lists subscribers most recent first", %{server: server} do
      pid = start_subscriber()

      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert :ok = Subscriptions.subscribe(server, "news", pid)
      assert :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      assert Subscriptions.subscribers(server, "news") == ["b@example.com", pid, "a@example.com"]
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

      assert :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails subscribed email addresses", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.subscribe(server, "news", "b@example.com")

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:delivered, "a@example.com", "New on news"}
      assert_receive {:delivered, "b@example.com", "New on news"}
    end

    test "notifies processes and email addresses on the same topic", %{server: server} do
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

    test "does nothing for a topic without subscribers", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :hello)
      assert sync(server) == []
      refute_received _
    end

    test "keeps notifying when the mailer returns an error", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "ok@example.com")
      :ok = Subscriptions.subscribe(server, "news", "fail@example.com")

      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:delivered, "fail@example.com", "New on news"}
      assert_receive {:delivered, "ok@example.com", "New on news"}
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits" do
    test "it is removed from every topic", %{server: server} do
      pid = start_subscriber()
      other = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sports", pid)
      :ok = Subscriptions.subscribe(server, "news", other)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      stop(pid)

      assert Subscriptions.subscribers(server, "news") == ["a@example.com", other]
      assert Subscriptions.subscribers(server, "sports") == []
    end

    test "it is no longer notified and the server keeps publishing", %{server: server} do
      pid = start_subscriber()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", self())

      stop(pid)
      :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  # Stops `pid` and waits until it is down. The server's own :DOWN message is
  # sent at the same moment, so it is handled before any later call.
  defp stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end
end
