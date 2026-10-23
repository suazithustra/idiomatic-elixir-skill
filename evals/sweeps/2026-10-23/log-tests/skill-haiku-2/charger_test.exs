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

  import ExUnit.CaptureLog

  alias Payments.Charger
  alias Payments.ChargerTest.ApprovingGateway
  alias Payments.ChargerTest.DecliningGateway
  alias Payments.ChargerTest.UnavailableGateway

  @log_format "[$level] $metadata$message\n"

  describe "charge/3 when the gateway declines" do
    test "returns the decline reason" do
      assert {{:error, :declined}, _log} = charge(DecliningGateway, 1999, "req_decline")
    end

    test "logs one warning with the request id and the amount as metadata" do
      {_result, log} = charge(DecliningGateway, 1999, "req_decline")

      assert [line] = log_lines(log)
      assert line =~ "[warning]"
      assert line =~ "card declined"
      assert line =~ "request_id=req_decline"
      assert line =~ "amount_cents=1999"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable reason" do
      assert {{:error, :unavailable}, _log} = charge(UnavailableGateway, 500, "req_down")
    end

    test "logs one error with the request id and the amount as metadata" do
      {_result, log} = charge(UnavailableGateway, 500, "req_down")

      assert [line] = log_lines(log)
      assert line =~ "[error]"
      assert line =~ "gateway unavailable, charge not attempted"
      assert line =~ "request_id=req_down"
      assert line =~ "amount_cents=500"
    end
  end

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      assert {{:ok, "ch_1"}, _log} = charge(ApprovingGateway, 750, "req_ok")
    end

    test "logs nothing at warning level or above" do
      {_result, log} = charge(ApprovingGateway, 750, "req_ok")

      refute log =~ ~r/\[(warning|error)\]/
    end
  end

  # Runs the charge with the log captured and formatted with the request id and
  # the amount, so the metadata can be checked as text.
  defp charge(gateway, amount_cents, request_id) do
    with_log(
      [format: @log_format, metadata: [:request_id, :amount_cents], colors: [enabled: false]],
      fn ->
        Charger.charge(amount_cents, "tok_visa", gateway: gateway, request_id: request_id)
      end
    )
  end

  defp log_lines(log), do: String.split(log, "\n", trim: true)
end
