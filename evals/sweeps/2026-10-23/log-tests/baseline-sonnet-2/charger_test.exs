ExUnit.start()

defmodule Payments.ChargerTest.LogForwarder do
  @moduledoc false
  # An Erlang :logger handler that forwards each event to the test process.
  def log(event, %{config: %{test_pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule Payments.ChargerTest.ApprovingGateway do
  @behaviour Payments.Gateway
  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.ChargerTest.DecliningGateway do
  @behaviour Payments.Gateway
  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.ChargerTest.DownGateway do
  @behaviour Payments.Gateway
  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  alias Payments.Charger
  alias Payments.ChargerTest.{ApprovingGateway, DecliningGateway, DownGateway, LogForwarder}

  setup do
    id = :"charger_test_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, LogForwarder, %{config: %{test_pid: self()}})
    on_exit(fn -> :logger.remove_handler(id) end)
    :ok
  end

  # Events logged by the test process itself, in order. Logging is synchronous
  # to the handler, so everything is already in the mailbox when charge/3 returns.
  defp collect_events(acc \\ []) do
    receive do
      {:log_event, %{meta: %{pid: pid}} = event} when pid == self() ->
        collect_events([event | acc])

      {:log_event, _other} ->
        collect_events(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp severe?(%{level: level}), do: level in [:warning, :error, :critical, :alert, :emergency]

  describe "charge/3 when the card is declined" do
    test "returns the error and logs a warning with request id and amount" do
      assert {:error, :declined} =
               Charger.charge(2500, "tok_1",
                 gateway: DecliningGateway,
                 request_id: "req-declined"
               )

      assert [event] = Enum.filter(collect_events(), &severe?/1)
      assert event.level == :warning
      assert event.meta.request_id == "req-declined"
      assert event.meta.amount_cents == 2500
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the error and logs at error level" do
      assert {:error, :unavailable} =
               Charger.charge(1800, "tok_2", gateway: DownGateway, request_id: "req-down")

      assert [event] = Enum.filter(collect_events(), &severe?/1)
      assert event.level == :error
      assert event.meta.request_id == "req-down"
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id and logs nothing at warning level or above" do
      assert {:ok, "ch_123"} =
               Charger.charge(999, "tok_3", gateway: ApprovingGateway, request_id: "req-ok")

      events = collect_events()
      refute Enum.any?(events, &severe?/1)
    end

    test "still carries the request id on its info log" do
      Charger.charge(999, "tok_3", gateway: ApprovingGateway, request_id: "req-ok")

      assert [%{level: :info, meta: %{request_id: "req-ok"}}] = collect_events()
    end
  end
end
