ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

  defmodule StubGateway do
    @moduledoc false
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
    def charge(_amount_cents, "tok_down"), do: {:error, :unavailable}
    def charge(_amount_cents, _token), do: {:ok, "ch_1"}
  end

  @log_format "$level $metadata$message\n"

  defp charge(token, amount_cents) do
    with_log(
      [
        format: @log_format,
        metadata: [:request_id, :charge_id, :amount_cents],
        colors: [enabled: false]
      ],
      fn ->
        Payments.Charger.charge(amount_cents, token,
          gateway: StubGateway,
          request_id: "req_42"
        )
      end
    )
  end

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      {result, _log} = charge("tok_ok", 250)

      assert result == {:ok, "ch_1"}
    end

    test "logs nothing at warning level or above" do
      {_result, log} = charge("tok_ok", 250)

      assert log =~ "charged 250 cents"
      refute log =~ ~r/^(emergency|alert|critical|error|warning) /m
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      {result, _log} = charge("tok_declined", 250)

      assert result == {:error, :declined}
    end

    test "logs a warning with the request id and the amount" do
      {_result, log} = charge("tok_declined", 250)

      assert log =~ ~r/^warning request_id=req_42 amount_cents=250 card declined$/m
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      {result, _log} = charge("tok_down", 250)

      assert result == {:error, :unavailable}
    end

    test "logs an error with the request id and the amount" do
      {_result, log} = charge("tok_down", 250)

      assert log =~ ~r/^error request_id=req_42 amount_cents=250 gateway unavailable/m
    end
  end
end

