ExUnit.start()

defmodule Notify.SubscriptionsTest.Mailer do
  @moduledoc false
  @behaviour Notify.Mailer

  # Reports each delivery to the test process registered as :mail_probe.
  @impl true
  def deliver(to, subject) do
    send(:mail_probe, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.Mailer

  setup do
    start_supervised!({Subscriptions, mailer: Mailer})
    Process.register(self(), :mail_probe)
    :ok
  end

  describe "subscribe/3 and subscribers/2" do
    test "subscribe returns :ok" do
      assert Subscriptions.subscribe("news", self()) == :ok
    end

    test "lists subscribers most recent first" do
      Subscriptions.subscribe("news", self())
      Subscriptions.subscribe("news", "ada@example.com")

      assert Subscriptions.subscribers("news") == ["ada@example.com", self()]
    end

    test "returns an empty list for a topic without subscribers" do
      assert Subscriptions.subscribers("news") == []
    end

    test "keeps the subscribers of different topics apart" do
      Subscriptions.subscribe("news", self())

      assert Subscriptions.subscribers("sport") == []
    end

    test "accepts a custom server name" do
      start_supervised!({Subscriptions, mailer: Mailer, name: :custom_subs}, id: :custom)

      Subscriptions.subscribe(:custom_subs, "news", self())
      Subscriptions.publish(:custom_subs, "news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert Subscriptions.subscribers(:custom_subs, "news") == [self()]
      assert Subscriptions.subscribers("news") == []
    end
  end

  describe "publish/3" do
    test "returns :ok" do
      assert Subscriptions.publish("news", "hello") == :ok
    end

    test "sends a notification to a subscribed pid" do
      Subscriptions.subscribe("news", self())
      Subscriptions.publish("news", "hello")

      assert_receive {:notification, "news", "hello"}
    end

    test "sends a notification to every subscribed pid" do
      parent = self()

      for _ <- 1..2 do
        pid =
          spawn(fn ->
            receive do
              {:notification, topic, payload} -> send(parent, {:got, self(), topic, payload})
            end
          end)

        Subscriptions.subscribe("news", pid)
      end

      Subscriptions.publish("news", "hello")

      assert_receive {:got, _, "news", "hello"}
      assert_receive {:got, _, "news", "hello"}
    end

    test "delivers to an email subscriber through the mailer with the topic in the subject" do
      Subscriptions.subscribe("news", "ada@example.com")
      Subscriptions.publish("news", "hello")

      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "delivers to every email subscriber" do
      Subscriptions.subscribe("news", "ada@example.com")
      Subscriptions.subscribe("news", "grace@example.com")
      Subscriptions.publish("news", "hello")

      assert_receive {:delivered, "ada@example.com", "New on news"}
      assert_receive {:delivered, "grace@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic alike" do
      Subscriptions.subscribe("news", self())
      Subscriptions.subscribe("news", "ada@example.com")
      Subscriptions.publish("news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert_receive {:delivered, "ada@example.com", "New on news"}
    end

    test "does not notify subscribers of other topics" do
      Subscriptions.subscribe("news", self())
      Subscriptions.subscribe("news", "ada@example.com")
      Subscriptions.publish("sport", "goal")

      # The call returns only after the cast above has been handled.
      assert Subscriptions.subscribers("sport") == []

      refute_receive {:notification, _, _}
      refute_receive {:delivered, _, _}
    end

    test "is a no-op for a topic without subscribers and keeps the server running" do
      server = Process.whereis(Subscriptions)

      Subscriptions.publish("news", "hello")

      assert Subscriptions.subscribers("news") == []
      assert Process.whereis(Subscriptions) == server
      assert Process.alive?(server)
    end
  end

  describe "when a subscribed process exits" do
    test "removes the exited pid from its topic" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers("news") == [] end)
    end

    test "removes the exited pid from every topic it subscribed to" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("sport", pid)

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers("news") == [] end)
      wait_until(fn -> Subscriptions.subscribers("sport") == [] end)
    end

    test "keeps the other subscribers of the topic" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("news", self())

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers("news") == [self()] end)
    end

    test "leaves email subscribers in place" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("news", "ada@example.com")

      kill(pid)

      wait_until(fn -> Subscriptions.subscribers("news") == ["ada@example.com"] end)
    end

    test "publishing after the exit notifies the remaining subscribers and keeps the server running" do
      pid = spawn_idle()
      Subscriptions.subscribe("news", pid)
      Subscriptions.subscribe("news", self())

      kill(pid)
      Subscriptions.publish("news", "hello")

      assert_receive {:notification, "news", "hello"}
      assert Process.alive?(Process.whereis(Subscriptions))
    end
  end

  defp spawn_idle do
    spawn(fn -> Process.sleep(:infinity) end)
  end

  # Kills the process and waits until it is dead. The server's own :DOWN message
  # may arrive later than ours, so callers poll with wait_until/1.
  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp wait_until(fun, attempts \\ 100) do
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
