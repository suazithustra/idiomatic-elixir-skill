ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule ApprovingGateway do
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

  @log_options [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      opts = [gateway: ApprovingGateway, request_id: "req_1"]

      capture_log(fn ->
        assert Charger.charge(1_500, "tok_1", opts) == {:ok, "ch_1"}
      end)
    end

    test "logs nothing at warning level or above" do
      opts = [gateway: ApprovingGateway, request_id: "req_1"]

      log =
        capture_log([level: :warning], fn ->
          assert Charger.charge(1_500, "tok_1", opts) == {:ok, "ch_1"}
        end)

      assert log == ""
    end
  end

  describe "charge/3 when the gateway declines the card" do
    test "returns a declined error" do
      opts = [gateway: DecliningGateway, request_id: "req_2"]

      capture_log(fn ->
        assert Charger.charge(2_500, "tok_2", opts) == {:error, :declined}
      end)
    end

    test "logs a warning carrying the request id and the amount" do
      opts = [gateway: DecliningGateway, request_id: "req_2"]

      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(2_500, "tok_2", opts) == {:error, :declined}
        end)

      assert log =~ "warning"
      assert log =~ "request_id=req_2"
      assert log =~ "amount_cents=2500"
      assert log =~ "card declined"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      opts = [gateway: UnavailableGateway, request_id: "req_3"]

      capture_log(fn ->
        assert Charger.charge(900, "tok_3", opts) == {:error, :unavailable}
      end)
    end

    test "logs at error level with the request id" do
      opts = [gateway: UnavailableGateway, request_id: "req_3"]

      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(900, "tok_3", opts) == {:error, :unavailable}
        end)

      assert log =~ "error"
      assert log =~ "request_id=req_3"
      assert log =~ "gateway unavailable"
    end
  end
end
