ExUnit.start()

defmodule Payments.ApprovingGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl Payments.Gateway
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.DecliningGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl Payments.Gateway
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.UnavailableGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl Payments.Gateway
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  @log_format [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3" do
    test "returns the charge id when the gateway approves the card" do
      opts = [gateway: Payments.ApprovingGateway, request_id: "req_1"]

      {result, _log} = with_log(@log_format, fn -> Charger.charge(1_500, "tok_visa", opts) end)

      assert result == {:ok, "ch_123"}
    end

    test "logs nothing at warning level or above when the gateway approves the card" do
      opts = [gateway: Payments.ApprovingGateway, request_id: "req_1"]

      log =
        capture_log([level: :warning] ++ @log_format, fn ->
          assert {:ok, "ch_123"} = Charger.charge(1_500, "tok_visa", opts)
        end)

      assert log == ""
    end

    test "returns a declined error when the gateway declines the card" do
      opts = [gateway: Payments.DecliningGateway, request_id: "req_2"]

      {result, _log} =
        with_log(@log_format, fn -> Charger.charge(2_500, "tok_declined", opts) end)

      assert result == {:error, :declined}
    end

    test "logs a warning with the request id and amount when the gateway declines the card" do
      opts = [gateway: Payments.DecliningGateway, request_id: "req_2"]

      log =
        capture_log(@log_format, fn ->
          assert {:error, :declined} = Charger.charge(2_500, "tok_declined", opts)
        end)

      assert log =~ ~r/^warning .*card declined$/m
      assert log =~ "request_id=req_2"
      assert log =~ "amount_cents=2500"
    end

    test "returns an unavailable error when the gateway is down" do
      opts = [gateway: Payments.UnavailableGateway, request_id: "req_3"]

      {result, _log} = with_log(@log_format, fn -> Charger.charge(4_000, "tok_visa", opts) end)

      assert result == {:error, :unavailable}
    end

    test "logs an error with the request id when the gateway is down" do
      opts = [gateway: Payments.UnavailableGateway, request_id: "req_3"]

      log =
        capture_log(@log_format, fn ->
          assert {:error, :unavailable} = Charger.charge(4_000, "tok_visa", opts)
        end)

      assert log =~ ~r/^error .*gateway unavailable, charge not attempted$/m
      assert log =~ "request_id=req_3"
    end
  end
end
