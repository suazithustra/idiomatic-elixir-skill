ExUnit.start()
{:ok, _} = Application.ensure_all_started(:logger)

defmodule Payments.TestGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  # The token picks the gateway answer, so one module covers all three outcomes.
  @impl true
  def charge(_amount_cents, "declined"), do: {:error, :declined}
  def charge(_amount_cents, "unavailable"), do: {:error, :unavailable}
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Payments.Charger

  @handler_id :charger_test_forwarder
  @warning_or_above [:warning, :error, :critical, :alert, :emergency]

  defmodule Forwarder do
    @moduledoc false
    # Erlang :logger handler that forwards events logged by the test process to the test pid.
    def log(event, %{config: %{pid: pid}}) do
      if event.meta[:pid] == pid, do: send(pid, {:log_event, event})
      :ok
    end
  end

  setup do
    :ok = :logger.add_handler(@handler_id, Forwarder, %{level: :all, config: %{pid: self()}})
    on_exit(fn -> :logger.remove_handler(@handler_id) end)
    :ok
  end

  describe "declined card" do
    test "returns the declined error" do
      assert run_charge("declined") == {:error, :declined}
    end

    test "logs one warning carrying the request id and the amount" do
      run_charge("declined")

      assert [%{level: :warning} = event] = log_events()
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 4_200
    end
  end

  describe "unavailable gateway" do
    test "returns the unavailable error" do
      assert run_charge("unavailable") == {:error, :unavailable}
    end

    test "logs one error carrying the request id and the amount" do
      run_charge("unavailable")

      assert [%{level: :error} = event] = log_events()
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 4_200
    end
  end

  describe "successful charge" do
    test "returns the charge id" do
      assert run_charge("tok_ok") == {:ok, "ch_123"}
    end

    test "logs nothing at warning or above" do
      run_charge("tok_ok")

      refute Enum.any?(log_events(), &(&1.level in @warning_or_above))
    end

    test "logs the charge id at info" do
      run_charge("tok_ok")

      assert [%{level: :info} = event] = log_events()
      assert event.meta.charge_id == "ch_123"
    end
  end

  # Runs the charge in the test process, captures console output so it does not clutter
  # the test run, and returns the gateway outcome. Log events reach the test through the
  # forwarder handler, not through the captured output.
  defp run_charge(token) do
    capture_log(fn ->
      send(self(), {:outcome, Charger.charge(4_200, token, gateway: Payments.TestGateway, request_id: "req-42")})
    end)

    assert_received {:outcome, outcome}
    outcome
  end

  defp log_events do
    receive do
      {:log_event, event} -> [event | log_events()]
    after
      0 -> []
    end
  end
end
