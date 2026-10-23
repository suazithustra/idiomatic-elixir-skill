ExUnit.start()

defmodule Payments.ChargerTest do
  # Installs a global :logger handler, so the tests run serially.
  use ExUnit.Case, async: false

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
    # An Erlang :logger handler that sends each event logged by the test process back to it,
    # so tests can assert on level and metadata without parsing formatted output.
    def log(%{meta: %{pid: pid}} = event, %{config: %{test_pid: pid}}),
      do: send(pid, {:log_event, event})

    def log(_event, _config), do: :ok
  end

  @moduletag :capture_log

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(handler_id, ForwardingHandler, %{
        level: :all,
        config: %{test_pid: self()}
      })

    on_exit(fn -> :logger.remove_handler(handler_id) end)
    :ok
  end

  defp charge(gateway, amount_cents \\ 1_250) do
    Charger.charge(amount_cents, "tok_visa", gateway: gateway, request_id: "req-42")
  end

  defp logged_events do
    receive do
      {:log_event, event} -> [event | logged_events()]
    after
      0 -> []
    end
  end

  defp at_or_above?(%{level: level}, threshold), do: Logger.compare_levels(level, threshold) != :lt

  test "a successful charge returns the charge id and logs nothing at warning or above" do
    assert {:ok, "ch_123"} = charge(ApprovingGateway)

    assert Enum.filter(logged_events(), &at_or_above?(&1, :warning)) == []
  end

  test "a declined card logs a warning carrying the request id and the amount" do
    assert {:error, :declined} = charge(DecliningGateway, 1_250)

    assert [%{meta: meta}] = Enum.filter(logged_events(), &(&1.level == :warning))
    assert meta.request_id == "req-42"
    assert meta.amount_cents == 1_250
  end

  test "an unavailable gateway logs at error level" do
    assert {:error, :unavailable} = charge(UnavailableGateway)

    assert [%{meta: meta}] = Enum.filter(logged_events(), &(&1.level == :error))
    assert meta.request_id == "req-42"
  end
end
