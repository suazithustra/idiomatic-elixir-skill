ExUnit.start()

defmodule Payments.ChargerTest do
  # Not async: capture_log sees the logs of every process, and these tests compare the whole output.
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule FakeGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(amount_cents, token) do
      send(self(), {:gateway_charge, amount_cents, token})

      case token do
        "tok_approved" -> {:ok, "ch_123"}
        "tok_declined" -> {:error, :declined}
        "tok_unavailable" -> {:error, :unavailable}
      end
    end
  end

  # The default format drops metadata. This one keeps it, along with the level, and leaves out the
  # message so that rewording a log line does not fail a test.
  @log_format [format: "$metadata[$level]\n", metadata: [:request_id, :amount_cents, :charge_id]]

  defp charge(token, level) do
    with_log([level: level] ++ @log_format, fn ->
      Charger.charge(1250, token, gateway: FakeGateway, request_id: "req-abc")
    end)
  end

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      assert {{:ok, "ch_123"}, _log} = charge("tok_approved", :info)
    end

    test "passes the amount and the token to the gateway" do
      charge("tok_approved", :info)

      assert_received {:gateway_charge, 1250, "tok_approved"}
    end

    test "logs the charge at info level with the request id" do
      assert {_result, log} = charge("tok_approved", :info)

      assert log == "request_id=req-abc charge_id=ch_123 [info]\n"
    end

    test "logs nothing at warning level or above" do
      assert {_result, log} = charge("tok_approved", :warning)

      assert log == ""
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns the declined error" do
      assert {{:error, :declined}, _log} = charge("tok_declined", :warning)
    end

    test "logs a warning whose metadata carries the request id and the amount" do
      assert {_result, log} = charge("tok_declined", :warning)

      assert log == "request_id=req-abc amount_cents=1250 [warning]\n"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error" do
      assert {{:error, :unavailable}, _log} = charge("tok_unavailable", :warning)
    end

    test "logs at error level with the request id and the amount" do
      assert {_result, log} = charge("tok_unavailable", :warning)

      assert log == "request_id=req-abc amount_cents=1250 [error]\n"
    end
  end
end
