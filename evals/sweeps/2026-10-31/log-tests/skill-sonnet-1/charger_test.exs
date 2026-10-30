ExUnit.start()

defmodule Payments.ChargerTest.ApprovingGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_1"}
end

defmodule Payments.ChargerTest.DecliningGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.ChargerTest.UnavailableGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger
  alias Payments.ChargerTest.ApprovingGateway
  alias Payments.ChargerTest.DecliningGateway
  alias Payments.ChargerTest.UnavailableGateway

  @log_options [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      log =
        capture_log(fn ->
          assert Charger.charge(1_500, "tok_1", gateway: ApprovingGateway, request_id: "req_1") ==
                   {:ok, "ch_1"}
        end)

      assert log =~ "charged 1500 cents"
    end

    test "logs nothing at warning level or above" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, "ch_1"} =
                   Charger.charge(1_500, "tok_1", gateway: ApprovingGateway, request_id: "req_1")
        end)

      assert log == ""
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      capture_log(fn ->
        assert Charger.charge(2_500, "tok_2", gateway: DecliningGateway, request_id: "req_2") ==
                 {:error, :declined}
      end)
    end

    test "logs a warning with the request id and the amount as metadata" do
      log =
        capture_log(@log_options, fn ->
          assert {:error, :declined} =
                   Charger.charge(2_500, "tok_2", gateway: DecliningGateway, request_id: "req_2")
        end)

      assert log =~ "warning "
      assert log =~ "request_id=req_2"
      assert log =~ "amount_cents=2500"
      assert log =~ "card declined"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      capture_log(fn ->
        assert Charger.charge(3_500, "tok_3", gateway: UnavailableGateway, request_id: "req_3") ==
                 {:error, :unavailable}
      end)
    end

    test "logs at error level with the request id" do
      log =
        capture_log(@log_options, fn ->
          assert {:error, :unavailable} =
                   Charger.charge(3_500, "tok_3",
                     gateway: UnavailableGateway,
                     request_id: "req_3"
                   )
        end)

      assert log =~ "error "
      assert log =~ "request_id=req_3"
      assert log =~ "gateway unavailable"
    end
  end
end
