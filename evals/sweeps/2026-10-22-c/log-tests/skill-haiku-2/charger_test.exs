ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Payments.Charger

  @log_format [
    format: "[$level] $metadata$message\n",
    metadata: [:request_id, :amount_cents],
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

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      {result, _log} = charge_with_log(ApprovingGateway, 500)

      assert {:ok, "ch_1"} = result
    end

    test "logs the charge at info and nothing at warning or above" do
      {_result, log} = charge_with_log(ApprovingGateway, 500)

      assert log =~ "[info] request_id=req_1 charged 500 cents"
      refute log =~ ~r/^\[(warning|error|critical|alert|emergency)\]/m
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns the decline reason" do
      {result, _log} = charge_with_log(DecliningGateway, 500)

      assert {:error, :declined} = result
    end

    test "logs a warning whose metadata carries the request id and the amount" do
      {_result, log} = charge_with_log(DecliningGateway, 500)

      assert log =~ ~r/^\[warning\] request_id=req_1 amount_cents=500 card declined$/m
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable reason" do
      {result, _log} = charge_with_log(UnavailableGateway, 500)

      assert {:error, :unavailable} = result
    end

    test "logs an error whose metadata carries the request id and the amount" do
      {_result, log} = charge_with_log(UnavailableGateway, 500)

      assert log =~
               ~r/^\[error\] request_id=req_1 amount_cents=500 gateway unavailable, charge not attempted$/m
    end
  end

  defp charge_with_log(gateway, amount_cents) do
    with_log(@log_format, fn ->
      Charger.charge(amount_cents, "tok_1", gateway: gateway, request_id: "req_1")
    end)
  end
end
