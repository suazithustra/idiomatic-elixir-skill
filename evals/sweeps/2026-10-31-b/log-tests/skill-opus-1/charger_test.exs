ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule FakeGateway do
    @behaviour Payments.Gateway

    # The charge id repeats the amount, so a test sees what reached the gateway.
    @impl Payments.Gateway
    def charge(amount_cents, "tok_approved"), do: {:ok, "ch_#{amount_cents}"}
    def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
    def charge(_amount_cents, "tok_unavailable"), do: {:error, :unavailable}
  end

  @log_options [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3" do
    test "returns the charge id and logs nothing at warning level or above when approved" do
      opts = [gateway: FakeGateway, request_id: "req_approved"]

      log =
        capture_log([level: :warning] ++ @log_options, fn ->
          assert Charger.charge(1500, "tok_approved", opts) == {:ok, "ch_1500"}
        end)

      # Other async test modules can log during this capture, so `log == ""` could fail on them.
      refute log =~ "request_id=req_approved"
    end

    test "returns a declined error and logs a warning with the request id and amount" do
      opts = [gateway: FakeGateway, request_id: "req_declined"]

      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(1500, "tok_declined", opts) == {:error, :declined}
        end)

      assert log =~ "warning request_id=req_declined amount_cents=1500 card declined"
    end

    test "returns an unavailable error and logs at error level" do
      opts = [gateway: FakeGateway, request_id: "req_unavailable"]

      log =
        capture_log(@log_options, fn ->
          assert Charger.charge(1500, "tok_unavailable", opts) == {:error, :unavailable}
        end)

      assert log =~ "error request_id=req_unavailable amount_cents=1500 gateway unavailable"
    end
  end
end
