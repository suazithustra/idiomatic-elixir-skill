ExUnit.start()

defmodule Payments.StubGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, "tok_ok"), do: {:ok, "ch_1"}
  def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
  def charge(_amount_cents, "tok_down"), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

  @amount 500
  @request_id "req_1"
  @log_opts [
    format: "[$level] $metadata$message\n",
    metadata: [:request_id, :amount_cents, :charge_id],
    colors: [enabled: false]
  ]

  describe "charge/3 when the card is accepted" do
    test "returns the charge id" do
      {result, _log} = charge_with_log("tok_ok")

      assert result == {:ok, "ch_1"}
    end

    test "logs nothing at warning level or above" do
      {_result, log} = charge_with_log("tok_ok")

      refute log =~ "[warning]"
      refute log =~ "[error]"
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      {result, _log} = charge_with_log("tok_declined")

      assert result == {:error, :declined}
    end

    test "logs a warning with the request id and the amount" do
      {_result, log} = charge_with_log("tok_declined")

      assert log =~ "[warning]"
      assert log =~ "request_id=#{@request_id}"
      assert log =~ "amount_cents=#{@amount}"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      {result, _log} = charge_with_log("tok_down")

      assert result == {:error, :unavailable}
    end

    test "logs an error with the request id and the amount" do
      {_result, log} = charge_with_log("tok_down")

      assert log =~ "[error]"
      assert log =~ "request_id=#{@request_id}"
      assert log =~ "amount_cents=#{@amount}"
    end
  end

  defp charge_with_log(token) do
    with_log(@log_opts, fn ->
      Payments.Charger.charge(@amount, token,
        gateway: Payments.StubGateway,
        request_id: @request_id
      )
    end)
  end
end
