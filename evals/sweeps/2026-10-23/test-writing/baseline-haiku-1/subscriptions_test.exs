ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(:mailer_probe, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.FailingMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(_to, _subject), do: {:error, :smtp_down}
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Notify.Subscriptions

  setup do
    # Email deliveries from Notify.TestMailer are sent to the test process,
    # which is registered under this name for the duration of the test.
    Process.register(self(), :mailer_probe)

    name = unique_name()
    start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})

    %{server: name}
  end

  describe "subscribe/3 and subscribers/2" do
    test "subscribe/3 returns :ok", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", self())
    end

    test "lists a pid subscriber for its topic", %{server: server} do
      Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists an email subscriber for its topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "lists the most recent subscriber first", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["second@example.com", "first@example.com"]
    end

    test "keeps topics separate", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "returns an empty list for a topic nobody subscribed to", %{server: server} do
      assert Subscriptions.subscribers(server, "news") == []
    end
  end

  describe "publish/3 to pid subscribers" do
    test "publish/3 returns :ok", %{server: server} do
      assert :ok = Subscriptions.publish(server, "news", "hello")
    end

    test "sends a notification to each pid subscriber", %{server: server} do
      task = Task.async(fn -> receive do: ({:notification, _, _} = msg -> msg) end)

      Subscriptions.subscribe(server, "news", self())
      Subscriptions.subscribe(server, "news", task.pid)
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert Task.await(task) == {:notification, "news", "hello"}
    end

    test "passes the payload through unchanged", %{server: server} do
      Subscriptions.subscribe(server, "news", self())
      Subscriptions.publish(server, "news", %{score: 2})

      assert_receive {:notification, "news", %{score: 2}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sport", self())
      Subscriptions.publish(server, "news", "hello")

      # A call is processed after the earlier cast, so this waits for the publish.
      Subscriptions.subscribers(server, "news")
      refute_received {:notification, _, _}
    end

    test "does nothing when the topic has no subscribers", %{server: server} do
      Subscriptions.publish(server, "news", "hello")

      Subscriptions.subscribers(server, "news")
      refute_received {:notification, _, _}
    end
  end

  describe "publish/3 to email subscribers" do
    test "delivers an email with the topic in the subject", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "reader@example.com", "New on news"}
    end

    test "emails every email subscriber of the topic", %{server: server} do
      Subscriptions.subscribe(server, "news", "first@example.com")
      Subscriptions.subscribe(server, "news", "second@example.com")
      Subscriptions.publish(server, "news", "hello")

      assert_receive {:delivered, "first@example.com", "New on news"}
      assert_receive {:delivered, "second@example.com", "New on news"}
    end

    test "does not email subscribers of other topics", %{server: server} do
      Subscriptions.subscribe(server, "sport", "reader@example.com")
      Subscriptions.publish(server, "news", "hello")

      Subscriptions.subscribers(server, "news")
      refute_received {:delivered, _, _}
    end

    test "keeps email subscribers after a publish", %{server: server} do
      Subscriptions.subscribe(server, "news", "reader@example.com")
      Subscriptions.publish(server, "news", "first")
      Subscriptions.publish(server, "news", "second")

      assert_receive {:delivered, "reader@example.com", "New on news"}
      assert_receive {:delivered, "reader@example.com", "New on news"}
      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "keeps notifying after the mailer returns an error" do
      name = unique_name()

      pid =
        start_supervised!(
          Supervisor.child_spec(
            {Subscriptions, mailer: Notify.FailingMailer, name: name},
            id: :failing_subscriptions
          )
        )

      # Email is listed first, so it is handled before the pid subscriber is notified.
      Subscriptions.subscribe(name, "news", self())
      Subscriptions.subscribe(name, "news", "reader@example.com")
      Subscriptions.publish(name, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert Process.alive?(pid)
      assert Subscriptions.subscribers(name, "news") == ["reader@example.com", self()]
    end
  end

  describe "start_link/1" do
    test "fails without a :mailer option" do
      Process.flag(:trap_exit, true)

      capture_log(fn ->
        assert {:error, _reason} = Subscriptions.start_link(name: unique_name())
      end)
    end
  end

  describe "when a subscribed process exits" do
    test "removes a pid subscriber that exits normally", %{server: server} do
      pid = start_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      exit_process(pid, :normal)

      await_subscribers(server, "news", [])
    end

    test "removes a pid subscriber that crashes", %{server: server} do
      pid = start_subscriber()
      Subscriptions.subscribe(server, "news", pid)

      exit_process(pid, :boom)

      await_subscribers(server, "news", [])
    end

    test "removes the process from every topic it subscribed to", %{server: server} do
      pid = start_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "sport", pid)

      exit_process(pid, :normal)

      await_subscribers(server, "news", [])
      await_subscribers(server, "sport", [])
    end

    test "removes both entries of a process subscribed twice", %{server: server} do
      pid = start_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", pid)

      assert Subscriptions.subscribers(server, "news") == [pid, pid]

      exit_process(pid, :normal)

      await_subscribers(server, "news", [])
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = start_subscriber()
      Subscriptions.subscribe(server, "news", pid)
      Subscriptions.subscribe(server, "news", self())

      exit_process(pid, :normal)

      await_subscribers(server, "news", [self()])
    end

    test "keeps email subscribers", %{server: server} do
      pid = start_subscriber()
      Subscriptions.subscribe(server, "news", "reader@example.com")
      Subscriptions.subscribe(server, "news", pid)

      exit_process(pid, :normal)

      await_subscribers(server, "news", ["reader@example.com"])
    end

    test "removes a process that was already dead when it subscribed", %{server: server} do
      pid = start_subscriber()
      exit_process(pid, :normal)

      Subscriptions.subscribe(server, "news", pid)

      await_subscribers(server, "news", [])
    end
  end

  defp unique_name do
    :"subscriptions_#{System.unique_integer([:positive])}"
  end

  # Spawns a process that exits with the reason it is sent as `{:exit, reason}`.
  defp start_subscriber do
    spawn(fn ->
      receive do
        {:exit, reason} -> exit(reason)
      end
    end)
  end

  defp exit_process(pid, reason) do
    ref = Process.monitor(pid)
    send(pid, {:exit, reason})
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # The server removes exited pids when it handles the :DOWN message, which can
  # arrive after the test process has already seen the exit. Poll until it does.
  defp await_subscribers(server, topic, expected, attempts \\ 200) do
    cond do
      Subscriptions.subscribers(server, topic) == expected ->
        :ok

      attempts == 0 ->
        flunk("expected subscribers #{inspect(expected)} on #{topic}, " <>
                "got #{inspect(Subscriptions.subscribers(server, topic))}")

      true ->
        Process.sleep(5)
        await_subscribers(server, topic, expected, attempts - 1)
    end
  end
end
