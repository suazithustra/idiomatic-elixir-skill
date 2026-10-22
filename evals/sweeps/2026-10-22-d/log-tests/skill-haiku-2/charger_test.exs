ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Payments.Charger

  @amount_cents 500
  @request_id "req_1"
  @warning_or_above ~r/^(warning|error|critical|alert|emergency) /m
  @log_opts [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  defmodule FakeGateway do
    @moduledoc false
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, "tok_approved"), do: {:ok, "ch_1"}
    def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
    def charge(_amount_cents, "tok_unavailable"), do: {:error, :unavailable}
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      {result, _log} = charge_logged("tok_declined")

      assert result == {:error, :declined}
    end

    test "logs a warning with the request id and the amount" do
      {_result, log} = charge_logged("tok_declined")

      assert log == "warning request_id=req_1 amount_cents=500 card declined\n"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      {result, _log} = charge_logged("tok_unavailable")

      assert result == {:error, :unavailable}
    end

    test "logs an error with the amount" do
      {_result, log} = charge_logged("tok_unavailable")

      assert log ==
               "error request_id=req_1 amount_cents=500 gateway unavailable, charge not attempted\n"
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id" do
      {result, _log} = charge_logged("tok_approved")

      assert result == {:ok, "ch_1"}
    end

    test "logs nothing at warning level or above" do
      {_result, log} = charge_logged("tok_approved")

      refute log =~ @warning_or_above
    end
  end

  defp charge_logged(token) do
    with_log(@log_opts, fn ->
      Charger.charge(@amount_cents, token, gateway: FakeGateway, request_id: @request_id)
    end)
  end
end
