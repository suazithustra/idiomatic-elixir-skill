ExUnit.start()
Application.ensure_all_started(:logger)

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule ApprovedGateway do
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

  describe "charge/3 logging" do
    test "logs a warning with the request id and amount when the card is declined" do
      opts = [gateway: DecliningGateway, request_id: "req_1"]

      {result, log} =
        with_log([metadata: [:request_id, :amount_cents]], fn ->
          Charger.charge(500, "tok_1", opts)
        end)

      assert {:error, :declined} = result
      assert log =~ "[warning] card declined"
      assert log =~ "request_id=req_1"
      assert log =~ "amount_cents=500"
      refute log =~ "[error]"
    end

    test "logs an error, not a warning, when the gateway is unavailable" do
      opts = [gateway: UnavailableGateway, request_id: "req_2"]

      {result, log} =
        with_log(fn ->
          Charger.charge(500, "tok_2", opts)
        end)

      assert {:error, :unavailable} = result
      assert log =~ "[error] gateway unavailable, charge not attempted"
      refute log =~ "[warning]"
    end

    test "logs nothing at warning level or above when the charge succeeds" do
      opts = [gateway: ApprovedGateway, request_id: "req_3"]

      {result, log} =
        with_log(fn ->
          Charger.charge(500, "tok_3", opts)
        end)

      assert {:ok, "ch_1"} = result
      # The info line shows the capture was live, so the absence below means something.
      assert log =~ "[info] charged 500 cents"
      refute log =~ ~r/\[(warning|error|critical|alert|emergency)\]/
    end
  end
end
