ExUnit.start()

defmodule Notify.SubscriptionsTest.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @registry Notify.SubscriptionsTest.TestMailer.Registry

  # deliver/2 runs inside the server, so the server's registered name is the key
  # under which the test process registered itself.
  @impl true
  def deliver(to, subject) do
    {:registered_name, server} = Process.info(self(), :registered_name)
    [{test_pid, _value}] = Registry.lookup(@registry, server)
    send(test_pid, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  @registry Notify.SubscriptionsTest.TestMailer.Registry

  setup_all do
    start_supervised!({Registry, keys: :unique, name: @registry})
    :ok
  end

  setup %{module: module, test: test} do
    name = Module.concat(module, test)
    {:ok, _owner} = Registry.register(@registry, name, nil)
    server = start_supervised!({Subscriptions, mailer: TestMailer, name: name})
    %{server: server}
  end

  describe "start_link/1" do
    test "registers the server under the :name option", %{server: server, module: module, test: test} do
      assert Process.whereis(Module.concat(module, test)) == server
    end

    test "fails when the :mailer option is missing", %{module: module, test: test} do
      name = Module.concat(module, "#{test}_without_mailer")
      {result, _log} = with_log(fn -> start_supervised({Subscriptions, name: name}) end)

      assert {:error, _reason} = result
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "returns the subscribers of a topic, most recent first", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", "ben@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ben@example.com", "ana@example.com"]
    end

    test "keeps the subscribers of each topic apart", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "sport", "ben@example.com") == :ok

      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
      assert Subscriptions.subscribers(server, "sport") == ["ben@example.com"]
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end

    test "stores a pid subscriber as the calling process", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribers(server, "news") == [self()]
    end
  end

  describe "publish/3" do
    test "sends a notification message to a pid subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:notification, "news", :launched}
    end

    test "delivers an email to an email subscriber", %{server: server} do
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:notification, "news", :launched}
      assert_receive {:delivered, "ana@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      assert Subscriptions.subscribe(server, "sport", self()) == :ok
      assert Subscriptions.subscribe(server, "sport", "ben@example.com") == :ok

      assert Subscriptions.publish(server, "news", :launched) == :ok
      # publish/3 is a cast; the state read returns after the server has handled it.
      _ = :sys.get_state(server)

      refute_receive {:notification, _topic, _payload}
      refute_receive {:delivered, _to, _subject}
    end

    test "leaves the server running when the topic has no subscribers", %{server: server} do
      assert Subscriptions.publish(server, "news", :launched) == :ok

      assert Subscriptions.subscribers(server, "news") == []
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits" do
    test "removes the process from its topic after a normal exit", %{server: server} do
      pid = spawn_idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      exit_normally(pid)

      assert Subscriptions.subscribers(server, "news") == []
    end

    test "removes the process from every topic it subscribed to when it is killed", %{
      server: server
    } do
      pid = spawn_idle_process()
      assert Subscriptions.subscribe(server, "news", pid) == :ok
      assert Subscriptions.subscribe(server, "sport", pid) == :ok

      kill(pid)

      assert Subscriptions.subscribers(server, "news") == []
      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "keeps the other pid subscribers of the topic", %{server: server} do
      pid = spawn_idle_process()
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      exit_normally(pid)

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "keeps the email subscribers of the topic", %{server: server} do
      pid = spawn_idle_process()
      assert Subscriptions.subscribe(server, "news", "ana@example.com") == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      exit_normally(pid)

      assert Subscriptions.subscribers(server, "news") == ["ana@example.com"]
    end

    test "still notifies the remaining subscribers and keeps running", %{server: server} do
      pid = spawn_idle_process()
      assert Subscriptions.subscribe(server, "news", self()) == :ok
      assert Subscriptions.subscribe(server, "news", pid) == :ok

      kill(pid)

      assert Subscriptions.publish(server, "news", :launched) == :ok
      assert_receive {:notification, "news", :launched}
      assert Process.alive?(server)
    end
  end

  defp spawn_idle_process do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp exit_normally(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end

defmodule Notify.SubscriptionsDefaultNameTest do
  # The default name is global, so this module cannot run concurrently.
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.TestMailer

  setup do
    start_supervised!({Subscriptions, mailer: TestMailer})
    :ok
  end

  test "subscribe/2 and publish/2 use the server registered as Notify.Subscriptions" do
    assert Subscriptions.subscribe("news", self()) == :ok
    assert Subscriptions.subscribers("news") == [self()]

    assert Subscriptions.publish("news", :launched) == :ok
    assert_receive {:notification, "news", :launched}
  end
end
