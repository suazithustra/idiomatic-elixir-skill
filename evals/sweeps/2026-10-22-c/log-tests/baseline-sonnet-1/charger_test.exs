ExUnit.start()

defmodule Payments.ChargerTest.Forwarder do
  @moduledoc false
  # A :logger handler that forwards every event to the test process.
  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log, event})
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger
  alias Payments.ChargerTest.Forwarder

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

  defmodule DownGateway do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:error, :unavailable}
  end

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    :ok = :logger.add_handler(handler_id, Forwarder, %{level: :all, config: %{pid: self()}})

    on_exit(fn ->
      :logger.remove_handler(handler_id)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  defp charge(gateway, amount \\ 4200) do
    Charger.charge(amount, "tok_visa", gateway: gateway, request_id: "req-abc")
  end

  defp collect_events(acc \\ []) do
    receive do
      {:log, event} -> collect_events([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp message(%{msg: {:string, msg}}), do: IO.iodata_to_binary(msg)
  defp message(%{msg: {:report, report}}), do: inspect(report)

  defp message(%{msg: {format, args}}),
    do: format |> :io_lib.format(args) |> IO.iodata_to_binary()

  describe "charge/3 when the card is declined" do
    test "returns the error and logs one warning with request id and amount in metadata" do
      assert {:error, :declined} = charge(DecliningGateway, 4200)

      assert [event] = collect_events()
      assert event.level == :warning
      assert message(event) =~ "declined"
      assert event.meta.request_id == "req-abc"
      assert event.meta.amount_cents == 4200
    end

    test "carries the amount of the request that was declined" do
      assert {:error, :declined} = charge(DecliningGateway, 999)

      assert [%{meta: %{amount_cents: 999, request_id: "req-abc"}}] = collect_events()
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the error and logs at error level" do
      assert {:error, :unavailable} = charge(DownGateway, 1500)

      assert [event] = collect_events()
      assert event.level == :error
      assert message(event) =~ "unavailable"
      assert event.meta.request_id == "req-abc"
      assert event.meta.amount_cents == 1500
    end
  end

  describe "charge/3 when the charge succeeds" do
    test "returns the charge id and logs nothing at warning level or above" do
      assert {:ok, "ch_123"} = charge(ApprovingGateway)

      events = collect_events()
      refute Enum.any?(events, &(:logger.compare_levels(&1.level, :warning) in [:gt, :eq]))
    end

    test "logs the charge at info level with the request id" do
      assert {:ok, "ch_123"} = charge(ApprovingGateway)

      assert [event] = collect_events()
      assert event.level == :info
      assert event.meta.request_id == "req-abc"
      assert event.meta.charge_id == "ch_123"
    end
  end
end
