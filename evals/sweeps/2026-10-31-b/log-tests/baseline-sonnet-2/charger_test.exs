ExUnit.start()

defmodule Payments.ChargerTest.LogForwarder do
  @moduledoc false
  # An Erlang :logger handler that forwards events logged by one process to the test process.

  def log(%{meta: %{pid: pid}} = event, %{config: %{test_pid: test_pid, source: pid}}) do
    send(test_pid, {:log, event.level, event.meta})
  end

  def log(_event, _config), do: :ok
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  alias Payments.Charger
  alias Payments.ChargerTest.LogForwarder

  defmodule ApprovingGateway do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:ok, "ch_123"}
  end

  defmodule DecliningGateway do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:error, :declined}
  end

  defmodule UnavailableGateway do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:error, :unavailable}
  end

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(handler_id, LogForwarder, %{
        level: :all,
        config: %{test_pid: self(), source: self()}
      })

    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      :logger.remove_handler(handler_id)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  defp charge(gateway, amount, request_id) do
    Charger.charge(amount, "tok_abc", gateway: gateway, request_id: request_id)
  end

  defp drain_logs(acc \\ []) do
    receive do
      {:log, level, meta} -> drain_logs([{level, meta} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  test "a successful charge returns the charge id" do
    assert {:ok, "ch_123"} = charge(ApprovingGateway, 500, "req-1")
  end

  test "a successful charge logs nothing at warning level or above" do
    charge(ApprovingGateway, 500, "req-1")

    levels = Enum.map(drain_logs(), fn {level, _meta} -> level end)

    assert :info in levels
    refute Enum.any?(levels, &(&1 in [:warning, :error, :critical, :alert, :emergency]))
  end

  test "a declined card returns the error" do
    assert {:error, :declined} = charge(DecliningGateway, 750, "req-2")
  end

  test "a declined card logs a warning carrying the request id and the amount" do
    charge(DecliningGateway, 750, "req-2")

    assert [{:warning, meta}] = drain_logs()
    assert meta.request_id == "req-2"
    assert meta.amount_cents == 750
  end

  test "an unavailable gateway returns the error" do
    assert {:error, :unavailable} = charge(UnavailableGateway, 900, "req-3")
  end

  test "an unavailable gateway logs at error level" do
    charge(UnavailableGateway, 900, "req-3")

    assert [{:error, meta}] = drain_logs()
    assert meta.request_id == "req-3"
    assert meta.amount_cents == 900
  end
end
