ExUnit.start()

defmodule Notify.SubscriptionsTest.FakeMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(Application.fetch_env!(:notify, :mail_test_pid), {:mail, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions
  alias Notify.SubscriptionsTest.FakeMailer

  setup context do
    # The fake mailer reports deliveries to the test process through the app env.
    Application.put_env(:notify, :mail_test_pid, self())
    on_exit(fn -> Application.delete_env(:notify, :mail_test_pid) end)

    # The default-name test starts its own server under the default name.
    if context[:default_name] do
      :ok
    else
      name = :"subscriptions_#{System.unique_integer([:positive])}"
      start_supervised!({Subscriptions, mailer: FakeMailer, name: name})

      %{server: name}
    end
  end

  describe "subscribe/3 and subscribers/2" do
    test "lists a subscribed pid", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      assert Subscriptions.subscribers(server, "news") == [self()]
    end

    test "lists a subscribed email address", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end

    test "lists the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "first@example.com")
      :ok = Subscriptions.subscribe(server, "news", "second@example.com")

      assert Subscriptions.subscribers(server, "news") ==
               ["second@example.com", "first@example.com"]
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      assert Subscriptions.subscribers(server, "sport") == []
    end

    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert Subscriptions.subscribers(server, "nothing") == []
    end

    @tag :default_name
    test "uses Notify.Subscriptions as the default server name" do
      start_supervised!({Subscriptions, mailer: FakeMailer})

      :ok = Subscriptions.subscribe("news", "reader@example.com")

      assert Subscriptions.subscribers("news") == ["reader@example.com"]
    end
  end

  describe "publish/3" do
    test "sends {:notification, topic, payload} to a subscribed pid", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify a pid subscribed to another topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())

      :ok = Subscriptions.publish(server, "sport", :goal)

      refute_receive {:notification, _, _}
    end

    test "sends nothing when the topic has no subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "nothing", :hello)

      # A call from this process runs after the cast above, so the publish has been handled.
      assert Subscriptions.subscribers(server, "nothing") == []
      refute_receive _
    end

    test "delivers an email to an email subscriber through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", "hello")

      assert_receive {:mail, "reader@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      :ok = Subscriptions.publish(server, "news", :breaking)

      assert_receive {:notification, "news", :breaking}
      assert_receive {:mail, "reader@example.com", "New on news"}
    end
  end

  describe "when a subscribed process exits" do
    test "removes the exited pid from every topic it subscribed to", %{server: server} do
      pid = spawn_listener()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sport", pid)

      stop_and_wait(pid)

      assert await_subscribers(server, "news", []) == []
      assert await_subscribers(server, "sport", []) == []
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = spawn_listener()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")

      Process.exit(pid, :kill)

      assert await_subscribers(server, "news", ["reader@example.com"]) == ["reader@example.com"]
    end

    test "does not remove email subscribers", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "reader@example.com")
      pid = spawn_listener()

      # The unrelated pid never subscribed, so its exit must not change the email list.
      stop_and_wait(pid)

      assert Subscriptions.subscribers(server, "news") == ["reader@example.com"]
    end
  end

  # Starts a process that waits until it is told to stop.
  defp spawn_listener do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  # Stops the process and returns once it has exited.
  defp stop_and_wait(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
  end

  # The server handles :DOWN messages asynchronously, so poll until the list matches.
  defp await_subscribers(server, topic, expected, attempts \\ 50) do
    case Subscriptions.subscribers(server, topic) do
      ^expected ->
        expected

      _actual when attempts > 0 ->
        Process.sleep(10)
        await_subscribers(server, topic, expected, attempts - 1)

      actual ->
        actual
    end
  end
end
