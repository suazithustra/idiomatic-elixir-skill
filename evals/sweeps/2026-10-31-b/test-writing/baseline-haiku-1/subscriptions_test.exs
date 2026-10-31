ExUnit.start()

defmodule Notify.TestMailer do
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(:mail_probe, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  setup do
    Process.register(self(), :mail_probe)
    start_supervised!({Subscriptions, mailer: Notify.TestMailer})
    :ok
  end

  describe "start_link/1" do
    test "fails when :mailer is missing" do
      # The failed init exits the linked caller, so trap that exit to keep the test alive.
      Process.flag(:trap_exit, true)

      assert {:error, _reason} = Subscriptions.start_link(name: :no_mailer_subscriptions)
    end
  end

  describe "subscribe/2 and subscribers/1" do
    test "lists a subscribed pid under its topic" do
      Subscriptions.subscribe("news", self())

      assert Subscriptions.subscribers("news") == [self()]
    end

    test "lists subscribers most recent first" do
      Subscriptions.subscribe("news", "first@example.com")
      Subscriptions.subscribe("news", "second@example.com")

      assert Subscriptions.subscribers("news") == ["second@example.com", "first@example.com"]
    end

    test "keeps topics separate" do
      Subscriptions.subscribe("news", "news@example.com")
      Subscriptions.subscribe("sports", "sports@example.com")

      assert Subscriptions.subscribers("sports") == ["sports@example.com"]
    end

    test "returns an empty list for a topic with no subscribers" do
      assert Subscriptions.subscribers("nothing") == []
    end

    test "uses the server given as the first argument" do
      child = {Subscriptions, mailer: Notify.TestMailer, name: :custom_subscriptions}
      start_supervised!(Supervisor.child_spec(child, id: :custom_subscriptions))

      :ok = Subscriptions.subscribe(:custom_subscriptions, "news", "a@example.com")

      assert Subscriptions.subscribers(:custom_subscriptions, "news") == ["a@example.com"]
      assert Subscriptions.subscribers("news") == []
    end
  end

  describe "publish/2 to pid subscribers" do
    test "sends a notification to a subscribed pid" do
      Subscriptions.subscribe("news", self())

      Subscriptions.publish("news", "hello")

      assert_receive {:notification, "news", "hello"}
    end

    test "sends the notification to every subscribed pid" do
      parent = self()

      other =
        spawn(fn ->
          receive do
            message -> send(parent, {:other, message})
          end
        end)

      Subscriptions.subscribe("news", self())
      Subscriptions.subscribe("news", other)

      Subscriptions.publish("news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:other, {:notification, "news", "hello"}}
    end

    test "does not notify subscribers of other topics" do
      Subscriptions.subscribe("sports", self())

      Subscriptions.publish("news", "hello")

      refute_receive {:notification, _, _}, 100
    end

    test "does nothing for a topic with no subscribers" do
      assert Subscriptions.publish("nobody", "hello") == :ok
      assert Subscriptions.subscribers("nobody") == []
    end
  end

  describe "publish/2 to email subscribers" do
    test "mails each email subscriber through the mailer" do
      Subscriptions.subscribe("news", "a@example.com")

      Subscriptions.publish("news", "hello")

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "does not mail email subscribers of other topics" do
      Subscriptions.subscribe("sports", "a@example.com")

      Subscriptions.publish("news", "hello")

      refute_receive {:delivered, _, _}, 100
    end

    test "notifies pid subscribers and mails email subscribers on the same topic" do
      Subscriptions.subscribe("news", self())
      Subscriptions.subscribe("news", "a@example.com")

      Subscriptions.publish("news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end
  end

  describe "exit of a subscribed process" do
    test "removes an exited pid from its topic" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("news", "a@example.com")

      kill(pid)

      assert_eventually(fn -> Subscriptions.subscribers("news") == ["a@example.com"] end)
    end

    test "removes an exited pid from every topic it subscribed to" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("sports", pid)

      kill(pid)

      assert_eventually(fn ->
        Subscriptions.subscribers("news") == [] and Subscriptions.subscribers("sports") == []
      end)
    end

    test "keeps the other pid subscribers on the topic" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("news", self())

      kill(pid)

      assert_eventually(fn -> Subscriptions.subscribers("news") == [self()] end)
    end

    test "keeps working after a subscribed pid exits" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)

      kill(pid)
      assert_eventually(fn -> Subscriptions.subscribers("news") == [] end)

      Subscriptions.subscribe("news", self())
      Subscriptions.publish("news", "still here")

      assert_receive {:notification, "news", "still here"}
    end
  end

  defp spawn_idle do
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

  # The server handles the :DOWN message asynchronously, so the removal may
  # land after the test's own monitor fires. Poll briefly instead of racing it.
  defp assert_eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition was not met in time")

      true ->
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
    end
  end
end
