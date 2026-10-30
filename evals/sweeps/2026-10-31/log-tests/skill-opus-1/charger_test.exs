ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule FakeGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(amount_cents, "tok_approved"), do: {:ok, "ch_#{amount_cents}"}
    def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
    def charge(_amount_cents, "tok_unavailable"), do: {:error, :unavailable}
  end

  @opts [gateway: FakeGateway, request_id: "req_1"]

  describe "charge/3" do
    test "returns the charge id and logs nothing at warning level or above on approval" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, "ch_1500"} = Charger.charge(1500, "tok_approved", @opts)
        end)

      assert log == ""
    end

    test "returns a declined error and logs a warning carrying the request id and amount" do
      log =
        capture_log([metadata: [:request_id, :amount_cents]], fn ->
          assert {:error, :declined} = Charger.charge(1500, "tok_declined", @opts)
        end)

      assert log =~ "[warning]"
      assert log =~ "card declined"
      assert log =~ "request_id=req_1"
      assert log =~ "amount_cents=1500"
    end

    test "returns an unavailable error and logs at error level" do
      log =
        capture_log(fn ->
          assert {:error, :unavailable} = Charger.charge(1500, "tok_unavailable", @opts)
        end)

      assert log =~ "[error]"
      assert log =~ "gateway unavailable"
    end
  end
end
