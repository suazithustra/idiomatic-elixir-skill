ExUnit.start()

defmodule Payments.ChargerTest.Capture do
  @moduledoc false
  # Erlang logger handler that forwards every log event to the test process.
  def log(event, %{test_pid: pid}), do: send(pid, {:log_event, event})
end

defmodule Payments.ChargerTest.OkGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.ChargerTest.DeclinedGateway do
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
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  @handler_id :charger_test_capture
  @warning_or_above [:emergency, :alert, :critical, :error, :warning]

  setup do
    :ok =
      :logger.add_handler(@handler_id, Payments.ChargerTest.Capture, %{
        level: :all,
        test_pid: self()
      })

    on_exit(fn -> :logger.remove_handler(@handler_id) end)
    :ok
  end

  describe "charge/3 with a successful charge" do
    test "returns the charge id" do
      assert {:ok, "ch_123"} = charge(Payments.ChargerTest.OkGateway)
    end

    test "logs an info event with the charge id" do
      charge(Payments.ChargerTest.OkGateway)

      assert [event] = events_at(:info)
      assert message(event) == "charged 500 cents"
      assert event.meta.charge_id == "ch_123"
    end

    test "logs nothing at warning level or above" do
      charge(Payments.ChargerTest.OkGateway)

      assert [] = events_at(@warning_or_above)
    end
  end

  describe "charge/3 with a declined card" do
    test "returns the decline" do
      assert {:error, :declined} = charge(Payments.ChargerTest.DeclinedGateway)
    end

    test "logs a warning with the request id and amount as metadata" do
      charge(Payments.ChargerTest.DeclinedGateway)

      assert [event] = events_at(:warning)
      assert message(event) == "card declined"
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 500
    end
  end

  describe "charge/3 with an unavailable gateway" do
    test "returns the unavailable error" do
      assert {:error, :unavailable} = charge(Payments.ChargerTest.UnavailableGateway)
    end

    test "logs at error level with the amount as metadata" do
      charge(Payments.ChargerTest.UnavailableGateway)

      assert [event] = events_at(:error)
      assert message(event) == "gateway unavailable, charge not attempted"
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 500
    end
  end

  defp charge(gateway) do
    Payments.Charger.charge(500, "tok_abc", gateway: gateway, request_id: "req-42")
  end

  defp events_at(levels) when is_list(levels) do
    Enum.filter(drain_events(), &(&1.level in levels))
  end

  defp events_at(level), do: events_at([level])

  defp drain_events(acc \\ []) do
    receive do
      {:log_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp message(%{msg: {:string, string}}), do: IO.chardata_to_string(string)
  defp message(%{msg: {:format, format, args}}), do: IO.chardata_to_string(:io_lib.format(format, args))
end
