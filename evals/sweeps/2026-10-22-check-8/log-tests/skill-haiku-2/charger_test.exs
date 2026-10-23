ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Payments.Charger

  defmodule ApprovedGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:ok, "ch_1"}
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

  @log_format "[$level] $metadata$message\n"

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      assert {:ok, "ch_1"} =
               Charger.charge(500, "tok_visa",
                 gateway: ApprovedGateway,
                 request_id: "req_1"
               )
    end

    test "logs the charge at info and nothing at warning or above" do
      {_result, log} =
        with_log([format: @log_format, metadata: :all, colors: [enabled: false]], fn ->
          Charger.charge(500, "tok_visa", gateway: ApprovedGateway, request_id: "req_1")
        end)

      assert log =~ ~r/^\[info\] .*charged 500 cents$/m
      refute log =~ ~r/\[(warning|error|critical|alert|emergency)\]/
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      assert {:error, :declined} =
               Charger.charge(500, "tok_visa",
                 gateway: DecliningGateway,
                 request_id: "req_1"
               )
    end

    test "logs a warning carrying the request id and the amount" do
      {_result, log} =
        with_log([format: @log_format, metadata: :all, colors: [enabled: false]], fn ->
          Charger.charge(500, "tok_visa", gateway: DecliningGateway, request_id: "req_1")
        end)

      assert log =~ ~r/^\[warning\] .*card declined$/m
      assert log =~ ~r/^\[warning\] .*request_id=req_1/m
      assert log =~ ~r/^\[warning\] .*amount_cents=500/m
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      assert {:error, :unavailable} =
               Charger.charge(500, "tok_visa",
                 gateway: UnavailableGateway,
                 request_id: "req_1"
               )
    end

    test "logs an error saying the charge was not attempted" do
      {_result, log} =
        with_log([format: @log_format, metadata: :all, colors: [enabled: false]], fn ->
          Charger.charge(500, "tok_visa", gateway: UnavailableGateway, request_id: "req_1")
        end)

      assert log =~ ~r/^\[error\] .*gateway unavailable, charge not attempted$/m
    end
  end
end
