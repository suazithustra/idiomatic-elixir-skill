ExUnit.start()

defmodule Notify.TestMailer do
  @moduledoc false
  @behaviour Notify.Mailer

  @impl true
  def deliver(to, subject) do
    send(:notify_test_mail_sink, {:delivered, to, subject})
    :ok
  end
end

defmodule Notify.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Notify.Subscriptions

  # The test mailer reports to a registered name, which is global to the VM,
  # so these tests cannot run concurrently.
  setup do
    Process.register(self(), :notify_test_mail_sink)
    name = :"subscriptions_#{System.unique_integer([:positive])}"
    server = start_supervised!({Subscriptions, mailer: Notify.TestMailer, name: name})

    %{server: server}
  end

  describe "start_link/1" do
    test "registers under Notify.Subscriptions when no :name is given" do
      {:ok, pid} = Subscriptions.start_link(mailer: Notify.TestMailer)

      assert Process.whereis(Subscriptions) == pid
    end

    test "fails to start without a :mailer" do
      Process.flag(:trap_exit, true)

      assert {:error, _reason} = Subscriptions.start_link(name: :no_mailer_subscriptions)
    end
  end

  describe "subscribe/3" do
    test "adds an email address to the topic", %{server: server} do
      assert :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      assert ["a@example.com"] == Subscriptions.subscribers(server, "news")
    end
  end

  describe "subscribers/2" do
    test "returns an empty list for a topic with no subscribers", %{server: server} do
      assert [] == Subscriptions.subscribers(server, "news")
    end

    test "returns the most recent subscriber first", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "first@example.com")
      :ok = Subscriptions.subscribe(server, "news", "second@example.com")

      assert ["second@example.com", "first@example.com"] ==
               Subscriptions.subscribers(server, "news")
    end

    test "keeps the subscribers of each topic separate", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert [] == Subscriptions.subscribers(server, "sports")
    end

    test "lists pid and email subscribers together", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      assert ["a@example.com", self()] == Subscriptions.subscribers(server, "news")
    end
  end

  describe "publish/3" do
    test "sends a notification to a pid subscriber", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "news", %{id: 1})

      assert_receive {:notification, "news", %{id: 1}}
    end

    test "does not notify subscribers of other topics", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.publish(server, "sports", :score)
      :ok = Subscriptions.publish(server, "news", :headline)

      assert_receive {:notification, "news", :headline}
      refute_received {:notification, "sports", _}
    end

    test "mails an email subscriber through the mailer", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.publish(server, "news", :headline)

      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "notifies pid and email subscribers of the same topic", %{server: server} do
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")
      :ok = Subscriptions.publish(server, "news", :headline)

      assert_receive {:notification, "news", :headline}
      assert_receive {:delivered, "a@example.com", "New on news"}
    end

    test "sends nothing when the topic has no subscribers", %{server: server} do
      :ok = Subscriptions.publish(server, "news", :headline)

      # The call is handled after the cast, so any message the cast sent is already here.
      assert [] == Subscriptions.subscribers(server, "news")
      refute_received {:notification, _, _}
      refute_received {:delivered, _, _}
    end
  end

  describe "subscriber process exit" do
    test "removes a pid subscriber when it exits", %{server: server} do
      pid = idle_process()
      :ok = Subscriptions.subscribe(server, "news", pid)

      kill(pid)

      assert [] == Subscriptions.subscribers(server, "news")
    end

    test "removes the exited pid from every topic it subscribed to", %{server: server} do
      pid = idle_process()
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "sports", pid)

      kill(pid)

      assert [] == Subscriptions.subscribers(server, "news")
      assert [] == Subscriptions.subscribers(server, "sports")
    end

    test "keeps the other subscribers of the topic", %{server: server} do
      pid = idle_process()
      :ok = Subscriptions.subscribe(server, "news", self())
      :ok = Subscriptions.subscribe(server, "news", pid)
      :ok = Subscriptions.subscribe(server, "news", "a@example.com")

      kill(pid)

      assert ["a@example.com", self()] == Subscriptions.subscribers(server, "news")
    end
  end

  defp idle_process do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
