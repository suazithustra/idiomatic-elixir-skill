ExUnit.start()

defmodule Payments.ApprovingGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.DecliningGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.UnavailableGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.ApprovingGateway
  alias Payments.Charger
  alias Payments.DecliningGateway
  alias Payments.UnavailableGateway

  @log_options [format: "$level $metadata$message\n", metadata: [:request_id, :amount_cents]]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      opts = [gateway: ApprovingGateway, request_id: "req_1"]

      assert Charger.charge(2500, "tok_visa", opts) == {:ok, "ch_123"}
    end

    test "logs nothing at warning level or above" do
      opts = [gateway: ApprovingGateway, request_id: "req_1"]

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, "ch_123"} = Charger.charge(2500, "tok_visa", opts)
        end)

      assert log == ""
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      opts = [gateway: DecliningGateway, request_id: "req_2"]

      assert Charger.charge(1999, "tok_visa", opts) == {:error, :declined}
    end

    test "logs a warning carrying the request id and the amount" do
      opts = [gateway: DecliningGateway, request_id: "req_2"]

      log =
        capture_log(@log_options, fn ->
          assert {:error, :declined} = Charger.charge(1999, "tok_visa", opts)
        end)

      assert log =~ "warning "
      assert log =~ "request_id=req_2"
      assert log =~ "amount_cents=1999"
      assert log =~ "card declined"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      opts = [gateway: UnavailableGateway, request_id: "req_3"]

      assert Charger.charge(500, "tok_visa", opts) == {:error, :unavailable}
    end

    test "logs at error level" do
      opts = [gateway: UnavailableGateway, request_id: "req_3"]

      log =
        capture_log(@log_options, fn ->
          assert {:error, :unavailable} = Charger.charge(500, "tok_visa", opts)
        end)

      assert log =~ "error "
      assert log =~ "request_id=req_3"
      assert log =~ "gateway unavailable"
    end
  end
end
