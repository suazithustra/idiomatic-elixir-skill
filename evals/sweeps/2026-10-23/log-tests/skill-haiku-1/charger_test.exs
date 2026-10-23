ExUnit.start()

defmodule Payments.ChargerTest.ApprovingGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_1"}
end

defmodule Payments.ChargerTest.DecliningGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.ChargerTest.UnavailableGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias Payments.Charger
  alias Payments.ChargerTest.ApprovingGateway
  alias Payments.ChargerTest.DecliningGateway
  alias Payments.ChargerTest.UnavailableGateway

  @capture_opts [
    format: "[$level] $metadata$message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3 when the card is declined" do
    test "returns the declined error and logs a warning with the request id and amount" do
      {result, log} =
        with_log(@capture_opts, fn ->
          Charger.charge(500, "tok_1", gateway: DecliningGateway, request_id: "req_1")
        end)

      assert {:error, :declined} = result
      assert log == "[warning] request_id=req_1 amount_cents=500 card declined\n"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error and logs at error level with the amount" do
      {result, log} =
        with_log(@capture_opts, fn ->
          Charger.charge(500, "tok_1", gateway: UnavailableGateway, request_id: "req_1")
        end)

      assert {:error, :unavailable} = result

      assert log ==
               "[error] request_id=req_1 amount_cents=500 gateway unavailable, charge not attempted\n"
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id and logs nothing at warning level or above" do
      {result, log} =
        with_log(@capture_opts, fn ->
          Charger.charge(500, "tok_1", gateway: ApprovingGateway, request_id: "req_1")
        end)

      assert {:ok, "ch_1"} = result
      assert log =~ "[info] request_id=req_1 charged 500 cents"
      refute log =~ ~r/\[(warning|error)\]/
    end
  end
end
