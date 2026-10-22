ExUnit.start()

defmodule Payments.ChargerTest.Gateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, "tok_accepted"), do: {:ok, "ch_1"}
  def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
  def charge(_amount_cents, "tok_unavailable"), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger
  alias Payments.ChargerTest.Gateway

  @log_format [format: "$level $metadata$message\n", metadata: :all, colors: [enabled: false]]

  describe "charge/3" do
    test "returns the charge id for an accepted card" do
      {result, _log} = with_log(@log_format, fn -> charge("tok_accepted") end)

      assert result == {:ok, "ch_1"}
    end

    test "logs no warning or error for an accepted card" do
      {_result, log} = with_log(@log_format, fn -> charge("tok_accepted") end)

      # The info line proves the capture ran, so the refute below is not vacuous.
      assert log =~ ~r/^info .*charge_id=ch_1/m
      refute log =~ ~r/^(warning|error) /m
    end

    test "returns :declined and logs a warning with the request id and amount" do
      {result, log} = with_log(@log_format, fn -> charge("tok_declined") end)

      assert result == {:error, :declined}
      assert log =~ ~r/^warning .*card declined/m
      assert log =~ ~r/^warning .*request_id=req_1/m
      assert log =~ ~r/^warning .*amount_cents=4200/m
    end

    test "returns :unavailable and logs an error" do
      {result, log} = with_log(@log_format, fn -> charge("tok_unavailable") end)

      assert result == {:error, :unavailable}
      assert log =~ ~r/^error .*gateway unavailable, charge not attempted/m
    end
  end

  defp charge(token, amount_cents \\ 4200) do
    Charger.charge(amount_cents, token, gateway: Gateway, request_id: "req_1")
  end
end
