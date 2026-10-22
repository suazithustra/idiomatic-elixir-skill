ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule ApprovingGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:ok, "ch_123"}
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

  @log_options [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  defp charge_with_log(gateway, log_options \\ @log_options) do
    with_log(log_options, fn ->
      Charger.charge(4200, "tok_visa", gateway: gateway, request_id: "req_7")
    end)
  end

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      assert {{:ok, "ch_123"}, _log} = charge_with_log(ApprovingGateway)
    end

    test "logs nothing at warning level or above" do
      {_result, log} = charge_with_log(ApprovingGateway, [level: :warning] ++ @log_options)

      assert log == ""
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      assert {{:error, :declined}, _log} = charge_with_log(DecliningGateway)
    end

    test "logs a warning with the request id and the amount in its metadata" do
      {_result, log} = charge_with_log(DecliningGateway)

      assert log =~ "warning "
      assert log =~ "request_id=req_7"
      assert log =~ "amount_cents=4200"
      assert log =~ "card declined"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      assert {{:error, :unavailable}, _log} = charge_with_log(UnavailableGateway)
    end

    test "logs at error level with the request id in its metadata" do
      {_result, log} = charge_with_log(UnavailableGateway)

      assert log =~ "error "
      assert log =~ "request_id=req_7"
      assert log =~ "gateway unavailable"
    end
  end
end
