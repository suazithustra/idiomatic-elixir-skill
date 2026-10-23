ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Payments.Charger

  defmodule ApprovingGateway do
    @moduledoc false
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:ok, "ch_1"}
  end

  defmodule DecliningGateway do
    @moduledoc false
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :declined}
  end

  defmodule UnavailableGateway do
    @moduledoc false
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :unavailable}
  end

  # Under async: true a capture can also hold other test modules' log lines,
  # so each test looks only at the lines that carry its own request id.
  @capture_opts [
    format: "$metadata[$level] $message\n",
    metadata: [:request_id, :amount_cents],
    colors: [enabled: false]
  ]

  describe "charge/3" do
    test "returns the charge id and logs nothing at warning level or above when approved" do
      opts = [gateway: ApprovingGateway, request_id: "req_approved"]

      log =
        capture_log([level: :warning] ++ @capture_opts, fn ->
          assert Charger.charge(1500, "tok_visa", opts) == {:ok, "ch_1"}
        end)

      refute log =~ "request_id=req_approved"
    end

    test "returns :declined and logs a warning with the request id and amount" do
      opts = [gateway: DecliningGateway, request_id: "req_declined"]

      log =
        capture_log(@capture_opts, fn ->
          assert Charger.charge(1500, "tok_visa", opts) == {:error, :declined}
        end)

      assert log =~ "request_id=req_declined amount_cents=1500 [warning]"
    end

    test "returns :unavailable and logs an error with the request id and amount" do
      opts = [gateway: UnavailableGateway, request_id: "req_unavailable"]

      log =
        capture_log(@capture_opts, fn ->
          assert Charger.charge(1500, "tok_visa", opts) == {:error, :unavailable}
        end)

      assert log =~ "request_id=req_unavailable amount_cents=1500 [error]"
    end
  end
end
