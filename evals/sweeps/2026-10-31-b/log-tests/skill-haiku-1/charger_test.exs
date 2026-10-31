ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  @capture_opts [format: "[$level] $metadata$message\n", metadata: :all, colors: [enabled: false]]

  defmodule FakeGateway do
    @moduledoc false
    @behaviour Payments.Gateway

    # The token picks the answer, so no test shares state with another.
    @impl true
    def charge(_amount_cents, "tok_ok"), do: {:ok, "ch_1"}
    def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
    def charge(_amount_cents, "tok_down"), do: {:error, :unavailable}
  end

  setup do
    %{opts: [gateway: FakeGateway, request_id: "req_1"]}
  end

  describe "charge/3 when the gateway declines the card" do
    test "returns a decline error", %{opts: opts} do
      {result, _log} =
        with_log(@capture_opts, fn -> Charger.charge(500, "tok_declined", opts) end)

      assert result == {:error, :declined}
    end

    test "logs a warning with the request id and the amount", %{opts: opts} do
      {_result, log} =
        with_log(@capture_opts, fn -> Charger.charge(500, "tok_declined", opts) end)

      line = log_line(log, "card declined")
      assert line =~ "[warning]"
      assert line =~ "request_id=req_1"
      assert line =~ "amount_cents=500"
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns an unavailable error", %{opts: opts} do
      {result, _log} =
        with_log(@capture_opts, fn -> Charger.charge(500, "tok_down", opts) end)

      assert result == {:error, :unavailable}
    end

    test "logs an error with the request id and the amount", %{opts: opts} do
      {_result, log} =
        with_log(@capture_opts, fn -> Charger.charge(500, "tok_down", opts) end)

      line = log_line(log, "gateway unavailable")
      assert line =~ "[error]"
      assert line =~ "request_id=req_1"
      assert line =~ "amount_cents=500"
    end
  end

  describe "charge/3 when the gateway accepts the charge" do
    test "returns the charge id", %{opts: opts} do
      {result, _log} =
        with_log(@capture_opts, fn -> Charger.charge(500, "tok_ok", opts) end)

      assert result == {:ok, "ch_1"}
    end

    test "logs nothing at warning level or above", %{opts: opts} do
      {_result, log} =
        with_log(@capture_opts, fn -> Charger.charge(500, "tok_ok", opts) end)

      # The info line proves the capture ran, so the refutes below cannot pass on an empty log.
      assert log =~ "[info]"
      refute log =~ "[warning]"
      refute log =~ "[error]"
    end
  end

  defp log_line(log, text) do
    case Enum.find(String.split(log, "\n"), &String.contains?(&1, text)) do
      nil -> flunk("no log line contains #{inspect(text)}, log was: #{inspect(log)}")
      line -> line
    end
  end
end
