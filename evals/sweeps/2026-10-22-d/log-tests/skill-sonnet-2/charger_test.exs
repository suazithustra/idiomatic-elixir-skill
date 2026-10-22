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

  defmodule DownGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :unavailable}
  end

  @log_options [
    format: "[$level] $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3 when the card is declined" do
    test "returns the declined error and logs a warning with the request id and amount" do
      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(2500, "tok_1", gateway: DecliningGateway, request_id: "req_1") ==
                   {:error, :declined}
        end)

      assert log =~ "[warning]"
      assert log =~ "request_id=req_1"
      assert log =~ "amount_cents=2500"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error and logs at error level" do
      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(900, "tok_2", gateway: DownGateway, request_id: "req_2") ==
                   {:error, :unavailable}
        end)

      assert log =~ "[error]"
      assert log =~ "request_id=req_2"
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id and logs nothing at warning level or above" do
      log =
        capture_log([level: :warning], fn ->
          assert Charger.charge(1200, "tok_3", gateway: ApprovingGateway, request_id: "req_3") ==
                   {:ok, "ch_1"}
        end)

      assert log == ""
    end
  end
end
