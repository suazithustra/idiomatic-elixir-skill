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

  describe "charge/3" do
    test "returns the charge id and logs nothing at warning or above when the gateway approves" do
      opts = [gateway: ApprovingGateway, request_id: "req_1"]

      log =
        capture_log([level: :warning] ++ @log_options, fn ->
          assert Charger.charge(1500, "tok_visa", opts) == {:ok, "ch_1"}
        end)

      assert log == ""
    end

    test "returns a declined error and logs a warning with the request id and amount" do
      opts = [gateway: DecliningGateway, request_id: "req_2"]

      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(1500, "tok_visa", opts) == {:error, :declined}
        end)

      assert log =~ "warning request_id=req_2 amount_cents=1500 card declined"
    end

    test "returns an unavailable error and logs it at error level" do
      opts = [gateway: UnavailableGateway, request_id: "req_3"]

      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(1500, "tok_visa", opts) == {:error, :unavailable}
        end)

      assert log =~ "error request_id=req_3 amount_cents=1500 gateway unavailable"
    end
  end
end
