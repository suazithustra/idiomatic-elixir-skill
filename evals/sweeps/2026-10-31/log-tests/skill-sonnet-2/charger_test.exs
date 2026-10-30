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
      capture_log(fn ->
        result = Charger.charge(500, "tok_1", gateway: ApprovingGateway, request_id: "req_1")

        assert result == {:ok, "ch_1"}
      end)
    end

    test "logs nothing at warning level or above" do
      log =
        capture_log(@log_options, fn ->
          assert {:ok, "ch_1"} =
                   Charger.charge(500, "tok_1", gateway: ApprovingGateway, request_id: "req_1")
        end)

      assert log =~ "info request_id=req_1"
      refute log =~ ~r/^(warning|error|critical|alert|emergency)/m
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      capture_log(fn ->
        result = Charger.charge(500, "tok_1", gateway: DecliningGateway, request_id: "req_1")

        assert result == {:error, :declined}
      end)
    end

    test "logs a warning with the request id and the amount" do
      log =
        capture_log(@log_options, fn ->
          assert {:error, :declined} =
                   Charger.charge(500, "tok_1", gateway: DecliningGateway, request_id: "req_7")
        end)

      assert log =~ "warning request_id=req_7 amount_cents=500 card declined"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      capture_log(fn ->
        result = Charger.charge(500, "tok_1", gateway: UnavailableGateway, request_id: "req_1")

        assert result == {:error, :unavailable}
      end)
    end

    test "logs an error with the request id" do
      log =
        capture_log(@log_options, fn ->
          assert {:error, :unavailable} =
                   Charger.charge(900, "tok_1", gateway: UnavailableGateway, request_id: "req_9")
        end)

      assert log =~ "error request_id=req_9 amount_cents=900 gateway unavailable"
    end
  end
end
