ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  @log_opts [
    format: "$level $metadata$message\n",
    metadata: [:request_id, :amount_cents, :charge_id],
    colors: [enabled: false]
  ]

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

  describe "charge/3" do
    test "returns the decline and logs a warning with the request id and amount" do
      {result, log} =
        with_log(@log_opts, fn ->
          Charger.charge(1500, "tok_1", gateway: DecliningGateway, request_id: "req_1")
        end)

      assert result == {:error, :declined}
      assert log =~ ~r/^warning request_id=req_1 amount_cents=1500 card declined$/m
    end

    test "returns the unavailable error and logs an error with the request id and amount" do
      {result, log} =
        with_log(@log_opts, fn ->
          Charger.charge(1500, "tok_1", gateway: UnavailableGateway, request_id: "req_1")
        end)

      assert result == {:error, :unavailable}

      assert log =~
               ~r/^error request_id=req_1 amount_cents=1500 gateway unavailable, charge not attempted$/m
    end

    test "returns the charge id and logs nothing at warning level or above" do
      {result, log} =
        with_log(@log_opts, fn ->
          Charger.charge(1500, "tok_1", gateway: ApprovingGateway, request_id: "req_1")
        end)

      assert result == {:ok, "ch_1"}
      assert log =~ ~r/^info request_id=req_1 charge_id=ch_1 charged 1500 cents$/m
      refute log =~ ~r/^(warning|error) /m
    end
  end
end
