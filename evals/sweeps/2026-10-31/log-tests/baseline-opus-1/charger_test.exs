ExUnit.start()

defmodule Payments.ChargerTest do
  # Not async: capture_log sees log lines from every process, and these tests assert on the
  # whole capture.
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule ApprovingGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(amount_cents, token) do
      send(self(), {:gateway_charge, amount_cents, token})
      {:ok, "ch_123"}
    end
  end

  defmodule DecliningGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :declined}
  end

  defmodule UnavailableGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :unavailable}
  end

  @amount_cents 4200
  @token "tok_visa"
  @request_id "req-7f3a"

  # The default format drops metadata. One line per log call ties level and metadata together.
  @log_opts [format: "$level $metadata\n", metadata: [:request_id, :amount_cents, :charge_id]]

  defp charge(gateway) do
    Charger.charge(@amount_cents, @token, gateway: gateway, request_id: @request_id)
  end

  describe "charge/3 when the gateway approves" do
    test "returns the charge id and logs it at info level with the request id" do
      {result, log} = with_log(@log_opts, fn -> charge(ApprovingGateway) end)

      assert result == {:ok, "ch_123"}
      assert log == "info request_id=req-7f3a charge_id=ch_123 \n"
    end

    test "passes the amount and token to the gateway" do
      capture_log(fn -> charge(ApprovingGateway) end)

      assert_received {:gateway_charge, @amount_cents, @token}
    end

    test "logs nothing at warning level or above" do
      log = capture_log([level: :warning], fn -> charge(ApprovingGateway) end)

      assert log == ""
    end
  end

  describe "charge/3 when the gateway declines the card" do
    test "returns the error and logs a warning with the request id and amount" do
      {result, log} = with_log(@log_opts, fn -> charge(DecliningGateway) end)

      assert result == {:error, :declined}
      assert log == "warning request_id=req-7f3a amount_cents=4200 \n"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the error and logs at error level with the request id and amount" do
      {result, log} = with_log(@log_opts, fn -> charge(UnavailableGateway) end)

      assert result == {:error, :unavailable}
      assert log == "error request_id=req-7f3a amount_cents=4200 \n"
    end
  end
end
