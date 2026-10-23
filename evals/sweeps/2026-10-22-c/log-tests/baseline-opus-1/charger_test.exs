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

  defmodule ForwardingHandler do
    @moduledoc false
    # An Erlang :logger handler that sends every event logged by the test process back to it,
    # so tests can assert on level and metadata as data rather than on formatted text.
    def log(%{meta: %{pid: pid}} = event, %{config: %{test_pid: pid}}) do
      send(pid, {:log_event, event})
    end

    def log(_event, _config), do: :ok
  end

  setup context do
    handler_id = :"charger_test_#{context.test}"
    :ok = :logger.add_handler(handler_id, ForwardingHandler, %{config: %{test_pid: self()}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)
    :ok
  end

  defp charge(gateway, request_id) do
    # capture_log keeps the default console handler quiet; ForwardingHandler still sees the events.
    capture_log(fn ->
      send(self(), {:result, Charger.charge(4200, "tok_visa", gateway: gateway, request_id: request_id)})
    end)

    assert_received {:result, result}
    result
  end

  defp received_events do
    receive do
      {:log_event, event} -> [event | received_events()]
    after
      0 -> []
    end
  end

  test "a successful charge returns the charge id and logs nothing at warning or above" do
    assert charge(ApprovingGateway, "req-ok") == {:ok, "ch_123"}

    events = received_events()
    assert [%{level: :info, meta: %{request_id: "req-ok", charge_id: "ch_123"}}] = events
    assert Enum.all?(events, &(Logger.compare_levels(&1.level, :warning) == :lt))
  end

  test "a declined card returns the error and logs a warning with the request id and amount" do
    assert charge(DecliningGateway, "req-declined") == {:error, :declined}

    assert [%{level: :warning, meta: meta}] = received_events()
    assert meta.request_id == "req-declined"
    assert meta.amount_cents == 4200
  end

  test "an unavailable gateway returns the error and logs at error level" do
    assert charge(UnavailableGateway, "req-down") == {:error, :unavailable}

    assert [%{level: :error, meta: meta}] = received_events()
    assert meta.request_id == "req-down"
    assert meta.amount_cents == 4200
  end
end
