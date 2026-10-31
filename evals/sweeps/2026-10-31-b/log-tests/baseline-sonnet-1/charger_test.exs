ExUnit.start()

defmodule Payments.Charger.TestHandler do
  @moduledoc false
  # An Erlang :logger handler that forwards each log event, with its metadata, to a test process.

  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule Payments.Charger.DecliningGateway do
  @behaviour Payments.Gateway
  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.Charger.UnavailableGateway do
  @behaviour Payments.Gateway
  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.Charger.ApprovingGateway do
  @behaviour Payments.Gateway
  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger
  alias Payments.Charger.{ApprovingGateway, DecliningGateway, TestHandler, UnavailableGateway}

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    :ok = :logger.add_handler(handler_id, TestHandler, %{config: %{pid: self()}})

    on_exit(fn ->
      :logger.remove_handler(handler_id)
      Logger.configure(level: previous_level)
    end)

    Logger.reset_metadata()
    :ok
  end

  # Collects every log event the test process has received so far.
  defp drain_events(acc \\ []) do
    receive do
      {:log_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp message(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)
  defp message(%{msg: {:report, report}}), do: inspect(report)

  describe "charge/3 when the card is declined" do
    test "returns the error and logs one warning with request id and amount as metadata" do
      assert {:error, :declined} =
               Charger.charge(1250, "tok_1", gateway: DecliningGateway, request_id: "req-42")

      assert [event] = drain_events()
      assert event.level == :warning
      assert message(event) == "card declined"
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 1250
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the error and logs at error level with the request id" do
      assert {:error, :unavailable} =
               Charger.charge(990, "tok_2", gateway: UnavailableGateway, request_id: "req-43")

      assert [event] = drain_events()
      assert event.level == :error
      assert message(event) =~ "gateway unavailable"
      assert event.meta.request_id == "req-43"
      assert event.meta.amount_cents == 990
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id and logs nothing at warning level or above" do
      assert {:ok, "ch_123"} =
               Charger.charge(500, "tok_3", gateway: ApprovingGateway, request_id: "req-44")

      events = drain_events()

      assert Enum.all?(events, &(&1.level in [:debug, :info, :notice]))
      refute Enum.any?(events, &(&1.level in [:warning, :error, :critical, :alert, :emergency]))
    end

    test "carries the request id on its info log" do
      assert {:ok, "ch_123"} =
               Charger.charge(500, "tok_3", gateway: ApprovingGateway, request_id: "req-45")

      assert [event] = drain_events()
      assert event.level == :info
      assert event.meta.request_id == "req-45"
      assert event.meta.charge_id == "ch_123"
    end
  end
end
