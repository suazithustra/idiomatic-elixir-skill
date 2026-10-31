ExUnit.start()

defmodule Notify.TestMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(:subscriptions_test_owner, {:mail, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    # The mailer runs inside the server process, so it reaches the test
    # process through a registered name.
    Process.register(self(), :subscriptions_test_owner)

    name = :"subscriptions_#{System.unique_integer([:positive])}"
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})

    %{server: server}
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
    end

    test "lists an email subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "lists a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists subscribers most recent first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")
      Subscriptions.subscribe(server, "news", "third@example.com")

      assert Subscriptions.subscribers(server, "news") == [
               "third@example.com",
               "second@example.com",
               "first@example.com"
             ]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "news@example.com")
      Subscriptions.subscribe(server, "sports", "sports@example.com")

      assert Subscriptions.subscribers(server, "news") == ["news@example.com"]
      assert Subscriptions.subscribers(server, "sports") == ["sports@example.com"]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nobody") == []
    end
  end

  describe "publish/3" do
    test "returns :ok", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", :hello)
    end

    test "sends a notification tuple to a pid subscriber", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "mails an email subscriber with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")

      Subscriptions.publish(server, "news", "payload")

      assert_receive {:mail, "reader@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", "reader@example.com")

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      assert_receive {:mail, "reader@example.com", "New on news"}
    end

    test "notifies each subscriber once per publish", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      Subscriptions.publish(server, "news", :hello)

      assert_receive {:notification, "news", :hello}
      refute_receive {:notification, _, _}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sports", self())
      Subscriptions.subscribe(server, "sports", "sports@example.com")

      Subscriptions.publish(server, "news", :hello)

      # subscribers/2 is a call, so it runs after the publish cast has been handled.
      assert Subscriptions.subscribers(server, "news") == []
      refute_receive {:notification, _, _}
      refute_received {:mail, _, _}
    end

    test "publishing to a topic with no subscribers does nothing", %{server: server} do
      assert :ok = Subscriptions.publish(server, "nobody", :hello)

      assert Process.alive?(server)
      assert Subscriptions.subscribers(server, "nobody") == []
      refute_receive {:notification, _, _}
    end
  end

  describe "when a subscribed process exits" do
    test "removes a pid subscriber that is killed", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes a pid subscriber that exits normally", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)

      stop_normally(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end

    test "removes an exited pid from every topic it subscribed to", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sports", pid)

      kill(pid)

      wait_until(fn ->
        Subscriptions.subscribers(server, "news") == [] and
          Subscriptions.subscribers(server, "sports") == []
      end)
    end

    test "keeps the other subscribers of a topic", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "reader@example.com")

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["reader@example.com"] end)
    end

    test "does not notify the exited pid, but still mails email subscribers", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", "reader@example.com")
      kill(pid)
      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["reader@example.com"] end)

      assert :ok = Subscriptions.publish(server, "news", :hello)

      assert_receive {:mail, "reader@example.com", "New on news"}
      assert Process.alive?(server)
    end

    test "email subscribers are kept when an unrelated process exits", %{server: server} do
      pid = spawn_waiting_process()
      Subscriptions.subscribe(server, "news", "reader@example.com")
      Subscriptions.subscribe(server, "news", pid)

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == ["reader@example.com"] end)
    end

    test "removes a pid that was already dead when it subscribed", %{server: server} do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      Subscriptions.subscribe(server, "news", pid)

      wait_until(fn -> Subscriptions.subscribers(server, "news") == [] end)
    end
  end

  describe "start_link/1" do
    test "registers the server under the default name when no :name is given" do
      # The setup server already uses the id Subscriptions gets from `use GenServer`,
      # so this child needs its own id.
      child = Supervisor.child_spec({Subscriptions, mailer: Notify.TestMailer}, id: :default_name)
      start_supervised!(child)

      Subscriptions.subscribe("news", "reader@example.com")

      assert Subscriptions.subscribers("news") == ["reader@example.com"]
    end

    test "fails to start without a :mailer" do
      Process.flag(:trap_exit, true)
      # A unique name keeps this crashed server from clashing with the default-name test.
      name = :"subscriptions_no_mailer_#{System.unique_integer([:positive])}"

      assert {:error, _reason} = Subscriptions.start_link(name: name)
    end
  end

  # Helpers

  defp spawn_waiting_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp stop_normally(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  # The server learns about an exit from a DOWN message that is sent by the
  # runtime, so it can handle that message after the test has already seen
  # the subscriber die. Poll until the removal has happened.
  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
