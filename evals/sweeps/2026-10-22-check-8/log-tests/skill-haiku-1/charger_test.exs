ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule Gateway do
    @moduledoc false
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, "approved"), do: {:ok, "ch_123"}
    def charge(_amount_cents, "declined"), do: {:error, :declined}
    def charge(_amount_cents, "unavailable"), do: {:error, :unavailable}
  end

  @log_options [
    format: "[$level] $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  defp charge_logged(token, amount_cents) do
    with_log(@log_options, fn ->
      Charger.charge(amount_cents, token, gateway: Gateway, request_id: "req_42")
    end)
  end

  describe "charge/3 when the card is declined" do
    test "returns the decline" do
      {result, _log} = charge_logged("declined", 4_200)

      assert {:error, :declined} = result
    end

    test "logs a warning with the request id and the amount" do
      {_result, log} = charge_logged("declined", 4_200)

      assert log =~ "[warning] request_id=req_42 amount_cents=4200 card declined"
    end

    test "does not log at error level" do
      {_result, log} = charge_logged("declined", 4_200)

      refute log =~ "[error]"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error" do
      {result, _log} = charge_logged("unavailable", 4_200)

      assert {:error, :unavailable} = result
    end

    test "logs at error level with the request id and the amount" do
      {_result, log} = charge_logged("unavailable", 4_200)

      assert log =~
               "[error] request_id=req_42 amount_cents=4200 gateway unavailable, charge not attempted"
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id" do
      {result, _log} = charge_logged("approved", 4_200)

      assert {:ok, "ch_123"} = result
    end

    test "logs an info line, so the capture is live" do
      {_result, log} = charge_logged("approved", 4_200)

      assert log =~ "[info] request_id=req_42 charged 4200 cents"
    end

    test "logs nothing at warning level or above" do
      {_result, log} = charge_logged("approved", 4_200)

      refute log =~ ~r/\[(warning|error|critical|alert|emergency)\]/
    end
  end
end
