ExUnit.start()
{:ok, _apps} = Application.ensure_all_started(:logger)

defmodule Payments.ChargerTest.FakeGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, "tok_approved"), do: {:ok, "ch_1"}
  def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
  def charge(_amount_cents, "tok_unavailable"), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger
  alias Payments.ChargerTest.FakeGateway

  @log_format [format: "$level $metadata$message\n", metadata: :all, colors: [enabled: false]]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      {result, _log} =
        with_log(@log_format, fn ->
          Charger.charge(1000, "tok_approved", gateway: FakeGateway, request_id: "req_1")
        end)

      assert {:ok, "ch_1"} == result
    end

    test "logs nothing at warning level or above" do
      {_result, log} =
        with_log(@log_format, fn ->
          Charger.charge(1000, "tok_approved", gateway: FakeGateway, request_id: "req_1")
        end)

      assert [_line] = Regex.run(~r/^info .*charged 1000 cents$/m, log)
      refute log =~ ~r/^(warning|error) /m
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns a declined error" do
      {result, _log} =
        with_log(@log_format, fn ->
          Charger.charge(1999, "tok_declined", gateway: FakeGateway, request_id: "req_42")
        end)

      assert {:error, :declined} == result
    end

    test "logs a warning carrying the request id and the amount" do
      {_result, log} =
        with_log(@log_format, fn ->
          Charger.charge(1999, "tok_declined", gateway: FakeGateway, request_id: "req_42")
        end)

      assert [warning] = Regex.run(~r/^warning .*card declined$/m, log)
      assert warning =~ "request_id=req_42"
      assert warning =~ "amount_cents=1999"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error" do
      {result, _log} =
        with_log(@log_format, fn ->
          Charger.charge(1000, "tok_unavailable", gateway: FakeGateway, request_id: "req_7")
        end)

      assert {:error, :unavailable} == result
    end

    test "logs an error saying the charge was not attempted" do
      {_result, log} =
        with_log(@log_format, fn ->
          Charger.charge(1000, "tok_unavailable", gateway: FakeGateway, request_id: "req_7")
        end)

      assert [_line] = Regex.run(~r/^error .*gateway unavailable, charge not attempted$/m, log)
    end
  end
end
