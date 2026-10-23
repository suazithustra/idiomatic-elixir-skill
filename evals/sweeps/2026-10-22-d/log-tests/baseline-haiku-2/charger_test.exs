ExUnit.start()

defmodule Payments.ChargerTest.ApprovingGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_test_1"}
end

defmodule Payments.ChargerTest.DecliningGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.ChargerTest.UnavailableGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest.LogHandler do
  # Forwards only the events logged by the test process, so tests can run async.
  def log(%{meta: %{pid: pid}} = event, %{test_pid: pid}) do
    send(pid, {:log_event, event})
  end

  def log(_event, _config), do: :ok
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  alias Payments.Charger
  alias Payments.ChargerTest.{ApprovingGateway, DecliningGateway, LogHandler, UnavailableGateway}

  @warning_or_above [:warning, :error, :critical, :alert, :emergency]

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler_id, LogHandler, %{test_pid: self()})
    on_exit(fn -> :logger.remove_handler(handler_id) end)
    :ok
  end

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      {result, _console} =
        ExUnit.CaptureLog.with_log(fn ->
          Charger.charge(500, "tok_visa", gateway: ApprovingGateway, request_id: "req-1")
        end)

      assert {:ok, "ch_test_1"} = result
    end

    test "logs the charge at info level" do
      ExUnit.CaptureLog.with_log(fn ->
        Charger.charge(500, "tok_visa", gateway: ApprovingGateway, request_id: "req-1")
      end)

      assert [%{level: :info, meta: meta}] = collect_events()
      assert meta.charge_id == "ch_test_1"
    end

    test "logs nothing at warning level or above" do
      ExUnit.CaptureLog.with_log(fn ->
        Charger.charge(500, "tok_visa", gateway: ApprovingGateway, request_id: "req-1")
      end)

      assert [] = warnings_or_above(collect_events())
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns the decline" do
      {result, _console} =
        ExUnit.CaptureLog.with_log(fn ->
          Charger.charge(500, "tok_declined", gateway: DecliningGateway, request_id: "req-2")
        end)

      assert {:error, :declined} = result
    end

    test "logs a warning carrying the request id and the amount" do
      ExUnit.CaptureLog.with_log(fn ->
        Charger.charge(500, "tok_declined", gateway: DecliningGateway, request_id: "req-2")
      end)

      assert [%{level: :warning, meta: meta}] = warnings_or_above(collect_events())
      assert meta.request_id == "req-2"
      assert meta.amount_cents == 500
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error" do
      {result, _console} =
        ExUnit.CaptureLog.with_log(fn ->
          Charger.charge(500, "tok_visa", gateway: UnavailableGateway, request_id: "req-3")
        end)

      assert {:error, :unavailable} = result
    end

    test "logs an error carrying the request id and the amount" do
      ExUnit.CaptureLog.with_log(fn ->
        Charger.charge(500, "tok_visa", gateway: UnavailableGateway, request_id: "req-3")
      end)

      assert [%{level: :error, meta: meta}] = warnings_or_above(collect_events())
      assert meta.request_id == "req-3"
      assert meta.amount_cents == 500
    end
  end

  defp collect_events(acc \\ []) do
    receive do
      {:log_event, event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp warnings_or_above(events) do
    Enum.filter(events, &(&1.level in @warning_or_above))
  end
end
