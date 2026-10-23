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

  @log_options [metadata: [:request_id, :amount_cents], colors: [enabled: false]]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      capture_log(fn ->
        assert Charger.charge(1_500, "tok_1", gateway: ApprovingGateway, request_id: "req_1") ==
                 {:ok, "ch_1"}
      end)
    end

    test "logs nothing at warning level or above" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, _charge_id} =
                   Charger.charge(1_500, "tok_1", gateway: ApprovingGateway, request_id: "req_1")
        end)

      assert log == ""
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns the declined error" do
      capture_log(fn ->
        assert Charger.charge(2_500, "tok_2", gateway: DecliningGateway, request_id: "req_2") ==
                 {:error, :declined}
      end)
    end

    test "logs a warning carrying the request id and the amount" do
      log =
        capture_log(@log_options, fn ->
          assert {:error, :declined} =
                   Charger.charge(2_500, "tok_2",
                     gateway: DecliningGateway,
                     request_id: "req_2"
                   )
        end)

      assert log =~ "[warning]"
      assert log =~ "request_id=req_2"
      assert log =~ "amount_cents=2500"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error" do
      capture_log(fn ->
        assert Charger.charge(3_500, "tok_3", gateway: DownGateway, request_id: "req_3") ==
                 {:error, :unavailable}
      end)
    end

    test "logs at error level" do
      log =
        capture_log(@log_options, fn ->
          assert {:error, :unavailable} =
                   Charger.charge(3_500, "tok_3", gateway: DownGateway, request_id: "req_3")
        end)

      assert log =~ "[error]"
      assert log =~ "request_id=req_3"
    end
  end
end
