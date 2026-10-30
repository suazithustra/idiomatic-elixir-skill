ExUnit.start()

defmodule Payments.ChargerTest.Gateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
  def charge(_amount_cents, "tok_unavailable"), do: {:error, :unavailable}
  def charge(_amount_cents, _token), do: {:ok, "ch_1"}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger
  alias Payments.ChargerTest.Gateway

  @log_opts [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents, :charge_id],
    colors: [enabled: false]
  ]

  describe "when the gateway declines the card" do
    test "returns the decline reason" do
      capture_log(fn ->
        assert Charger.charge(500, "tok_declined", gateway: Gateway, request_id: "req_1") ==
                 {:error, :declined}
      end)
    end

    test "logs a warning with the request id and the amount" do
      log =
        capture_log(@log_opts, fn ->
          Charger.charge(500, "tok_declined", gateway: Gateway, request_id: "req_1")
        end)

      assert log =~ "warning request_id=req_1 amount_cents=500 card declined"
    end
  end

  describe "when the gateway is unavailable" do
    test "returns the unavailable reason" do
      capture_log(fn ->
        assert Charger.charge(500, "tok_unavailable", gateway: Gateway, request_id: "req_2") ==
                 {:error, :unavailable}
      end)
    end

    test "logs an error with the request id and the amount" do
      log =
        capture_log(@log_opts, fn ->
          Charger.charge(500, "tok_unavailable", gateway: Gateway, request_id: "req_2")
        end)

      assert log =~ ~r/^error request_id=req_2 amount_cents=500 gateway unavailable/m
    end
  end

  describe "when the charge succeeds" do
    test "returns the charge id" do
      capture_log(fn ->
        assert Charger.charge(500, "tok_ok", gateway: Gateway, request_id: "req_3") ==
                 {:ok, "ch_1"}
      end)
    end

    test "logs at info and nothing at warning or above" do
      log =
        capture_log(@log_opts, fn ->
          Charger.charge(500, "tok_ok", gateway: Gateway, request_id: "req_3")
        end)

      # The info line proves the capture ran, so the refute below cannot pass on an empty log.
      assert log =~ ~r/^info /m
      refute log =~ ~r/^(warning|error) /m
    end
  end
end
