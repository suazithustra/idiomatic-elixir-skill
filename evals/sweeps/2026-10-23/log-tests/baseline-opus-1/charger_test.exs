ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule ApprovingGateway do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:ok, "ch_123"}
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

  # One line per event, with the level and the metadata we care about, so assertions can
  # match a single log line instead of searching the whole capture.
  @log_format [format: "$level $metadata| $message\n", metadata: [:request_id, :amount_cents]]

  defp charge_with_log(gateway, request_id) do
    with_log(@log_format, fn ->
      Charger.charge(4200, "tok_visa", gateway: gateway, request_id: request_id)
    end)
  end

  test "a successful charge returns the charge id and logs nothing at warning or above" do
    {result, log} = charge_with_log(ApprovingGateway, "req-ok")

    assert result == {:ok, "ch_123"}
    # The info line shows the capture works, so the refute below is not vacuous.
    assert log =~ ~r/^info request_id=req-ok \| charged 4200 cents$/m
    refute log =~ ~r/^(warning|error|critical|alert|emergency) /m
  end

  test "a declined card logs a warning carrying the request id and the amount" do
    {result, log} = charge_with_log(DecliningGateway, "req-declined")

    assert result == {:error, :declined}
    assert log =~ ~r/^warning request_id=req-declined amount_cents=4200 \| card declined$/m
  end

  test "an unavailable gateway logs at error level" do
    {result, log} = charge_with_log(UnavailableGateway, "req-unavailable")

    assert result == {:error, :unavailable}

    assert log =~
             ~r/^error request_id=req-unavailable amount_cents=4200 \| gateway unavailable, charge not attempted$/m
  end
end
