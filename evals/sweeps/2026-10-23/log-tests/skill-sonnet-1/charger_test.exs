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

  @log_options [metadata: [:request_id, :amount_cents], colors: [enabled: false]]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id and logs nothing at warning level or above" do
      log =
        capture_log([level: :warning], fn ->
          result = Charger.charge(4200, "tok_1", gateway: ApprovingGateway, request_id: "req_1")

          assert result == {:ok, "ch_1"}
        end)

      assert log == ""
    end

    test "logs the charge at info level with the request id" do
      log =
        capture_log([metadata: [:request_id, :charge_id], colors: [enabled: false]], fn ->
          assert Charger.charge(4200, "tok_1", gateway: ApprovingGateway, request_id: "req_1") ==
                   {:ok, "ch_1"}
        end)

      assert log =~ "[info]"
      assert log =~ "charged 4200 cents"
      assert log =~ "request_id=req_1"
      assert log =~ "charge_id=ch_1"
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      capture_log(fn ->
        result = Charger.charge(4200, "tok_1", gateway: DecliningGateway, request_id: "req_2")

        assert result == {:error, :declined}
      end)
    end

    test "logs a warning carrying the request id and the amount" do
      log =
        capture_log(@log_options, fn ->
          Charger.charge(4200, "tok_1", gateway: DecliningGateway, request_id: "req_2")
        end)

      assert log =~ "[warning]"
      assert log =~ "card declined"
      assert log =~ "request_id=req_2"
      assert log =~ "amount_cents=4200"
    end

    test "does not log at error level" do
      log =
        capture_log([level: :error], fn ->
          Charger.charge(4200, "tok_1", gateway: DecliningGateway, request_id: "req_2")
        end)

      assert log == ""
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      capture_log(fn ->
        result = Charger.charge(900, "tok_1", gateway: UnavailableGateway, request_id: "req_3")

        assert result == {:error, :unavailable}
      end)
    end

    test "logs at error level with the request id and the amount" do
      log =
        capture_log(@log_options, fn ->
          Charger.charge(900, "tok_1", gateway: UnavailableGateway, request_id: "req_3")
        end)

      assert log =~ "[error]"
      assert log =~ "gateway unavailable"
      assert log =~ "request_id=req_3"
      assert log =~ "amount_cents=900"
    end
  end
end
