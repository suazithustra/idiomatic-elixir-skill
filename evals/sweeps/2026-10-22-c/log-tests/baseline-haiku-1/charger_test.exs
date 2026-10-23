ExUnit.start()

defmodule ChargerTest.Gateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, "tok_ok"), do: {:ok, "ch_123"}
  def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
  def charge(_amount_cents, "tok_down"), do: {:error, :unavailable}
end

defmodule ChargerTest.LogForwarder do
  # Erlang's logger runs handlers in the process that logged the event,
  # so self() is the test process that should receive the event.
  def log(event, _config) do
    send(self(), {:log, event})
  end
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Payments.Charger

  @handler_id :charger_test_log_forwarder
  @severe [:warning, :error, :critical, :alert, :emergency]

  setup do
    :ok = :logger.add_handler(@handler_id, ChargerTest.LogForwarder, %{})
    on_exit(fn -> :logger.remove_handler(@handler_id) end)
    :ok
  end

  describe "declined card" do
    test "returns the error and logs a warning with request id and amount" do
      assert {:error, :declined} =
               Charger.charge(4_200, "tok_declined",
                 gateway: ChargerTest.Gateway,
                 request_id: "req-42"
               )

      assert [%{level: :warning} = event] = drain_logs()
      assert message(event) == "card declined"
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 4_200
    end
  end

  describe "unavailable gateway" do
    test "returns the error and logs at error level" do
      assert {:error, :unavailable} =
               Charger.charge(1_000, "tok_down",
                 gateway: ChargerTest.Gateway,
                 request_id: "req-7"
               )

      assert [%{level: :error} = event] = drain_logs()
      assert message(event) == "gateway unavailable, charge not attempted"
      assert event.meta.request_id == "req-7"
      assert event.meta.amount_cents == 1_000
    end
  end

  describe "successful charge" do
    test "returns the charge id and logs nothing at warning or above" do
      assert {:ok, "ch_123"} =
               Charger.charge(500, "tok_ok",
                 gateway: ChargerTest.Gateway,
                 request_id: "req-1"
               )

      logs = drain_logs()

      refute Enum.any?(logs, &(&1.level in @severe))
      assert [%{level: :info, meta: %{charge_id: "ch_123"}}] = logs
    end
  end

  defp drain_logs(acc \\ []) do
    receive do
      {:log, event} -> drain_logs([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp message(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)
end
