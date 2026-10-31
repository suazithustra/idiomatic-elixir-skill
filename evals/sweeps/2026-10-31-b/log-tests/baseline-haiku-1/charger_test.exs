ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

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

  # A `:logger` handler that forwards every log event to the test process.
  defmodule EventForwarder do
    def log(event, %{config: %{test_pid: pid}}), do: send(pid, {:log_event, event})
  end

  @warning_or_above [:emergency, :alert, :critical, :error, :warning]

  setup do
    :ok = :logger.add_handler(:charger_test_forwarder, EventForwarder, %{config: %{test_pid: self()}})
    on_exit(fn -> :logger.remove_handler(:charger_test_forwarder) end)
    :ok
  end

  describe "charge/3 with a declined card" do
    test "returns {:error, :declined}" do
      assert {:error, :declined} = charge_quietly(DecliningGateway)
    end

    test "logs one warning carrying the request id and the amount" do
      {_result, events} = charge_and_collect(DecliningGateway)

      assert [%{level: :warning, msg: msg, meta: meta}] = events
      assert message(msg) == "card declined"
      assert meta.request_id == "req-42"
      assert meta.amount_cents == 2_500
    end
  end

  describe "charge/3 with an unavailable gateway" do
    test "returns {:error, :unavailable}" do
      assert {:error, :unavailable} = charge_quietly(UnavailableGateway)
    end

    test "logs at error level carrying the request id and the amount" do
      {_result, events} = charge_and_collect(UnavailableGateway)

      assert [%{level: :error, msg: msg, meta: meta}] = events
      assert message(msg) == "gateway unavailable, charge not attempted"
      assert meta.request_id == "req-42"
      assert meta.amount_cents == 2_500
    end
  end

  describe "charge/3 with an approved charge" do
    test "returns {:ok, charge_id}" do
      assert {:ok, "ch_123"} = charge_quietly(ApprovingGateway)
    end

    test "logs nothing at warning level or above" do
      {_result, events} = charge_and_collect(ApprovingGateway)

      assert Enum.filter(events, &(&1.level in @warning_or_above)) == []
    end

    test "logs only the info line with the charge id" do
      {_result, events} = charge_and_collect(ApprovingGateway)

      assert [%{level: :info, msg: msg, meta: meta}] = events
      assert message(msg) == "charged 2500 cents"
      assert meta.charge_id == "ch_123"
    end
  end

  defp charge(gateway) do
    Payments.Charger.charge(2_500, "tok_visa", gateway: gateway, request_id: "req-42")
  end

  # Runs the charge with console log output captured, so test output stays readable.
  defp charge_quietly(gateway) do
    ExUnit.CaptureLog.capture_log(fn -> send(self(), {:charge_result, charge(gateway)}) end)

    receive do
      {:charge_result, result} -> result
    end
  end

  defp charge_and_collect(gateway) do
    result = charge_quietly(gateway)
    {result, drain_log_events([])}
  end

  defp drain_log_events(acc) do
    receive do
      {:log_event, event} -> drain_log_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp message({:format, format, args}), do: IO.iodata_to_binary(:io_lib.format(format, args))
end
