ExUnit.start()

defmodule Payments.Charger.LogCollector do
  @moduledoc false

  # An Erlang :logger handler that forwards each event logged by the test process to that process.
  # Forwarding the raw event keeps the level and the metadata, which CaptureLog would flatten to text.
  def log(%{meta: meta} = event, %{config: %{test_pid: test_pid}}) do
    if meta[:pid] == test_pid, do: send(test_pid, {:log_event, event})
    :ok
  end
end

defmodule Payments.Charger.FakeGateways do
  @moduledoc false

  defmodule Approved do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:ok, "ch_123"}
  end

  defmodule Declined do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :declined}
  end

  defmodule Unavailable do
    @behaviour Payments.Gateway

    @impl true
    def charge(_amount_cents, _token), do: {:error, :unavailable}
  end
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger
  alias Payments.Charger.FakeGateways
  alias Payments.Charger.LogCollector

  @moduletag :capture_log

  @request_id "req-42"
  @amount_cents 1_250

  setup do
    handler = :"charger_log_collector_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(handler, LogCollector, %{
        level: :all,
        config: %{test_pid: self()}
      })

    on_exit(fn -> :logger.remove_handler(handler) end)

    :ok
  end

  describe "declined card" do
    test "returns the gateway's error" do
      assert {:error, :declined} =
               Charger.charge(@amount_cents, "tok",
                 gateway: FakeGateways.Declined,
                 request_id: @request_id
               )
    end

    test "logs a warning carrying the request id and the amount" do
      Charger.charge(@amount_cents, "tok",
        gateway: FakeGateways.Declined,
        request_id: @request_id
      )

      assert_receive {:log_event, %{level: :warning, meta: meta, msg: msg}}
      assert message(msg) == "card declined"
      assert meta[:request_id] == @request_id
      assert meta[:amount_cents] == @amount_cents
    end
  end

  describe "unavailable gateway" do
    test "returns the gateway's error" do
      assert {:error, :unavailable} =
               Charger.charge(@amount_cents, "tok",
                 gateway: FakeGateways.Unavailable,
                 request_id: @request_id
               )
    end

    test "logs at error level with the request id and the amount" do
      Charger.charge(@amount_cents, "tok",
        gateway: FakeGateways.Unavailable,
        request_id: @request_id
      )

      assert_receive {:log_event, %{level: :error, meta: meta, msg: msg}}
      assert message(msg) == "gateway unavailable, charge not attempted"
      assert meta[:request_id] == @request_id
      assert meta[:amount_cents] == @amount_cents
    end
  end

  describe "successful charge" do
    test "returns the charge id" do
      assert {:ok, "ch_123"} =
               Charger.charge(@amount_cents, "tok",
                 gateway: FakeGateways.Approved,
                 request_id: @request_id
               )
    end

    test "logs nothing at warning level or above" do
      Charger.charge(@amount_cents, "tok",
        gateway: FakeGateways.Approved,
        request_id: @request_id
      )

      events = drain_log_events()

      # The info line proves the collector saw this call's logs, so the check below is not vacuous.
      assert Enum.any?(events, &(&1.level == :info))
      refute Enum.any?(events, &(:logger.compare_levels(&1.level, :warning) in [:eq, :gt]))
    end
  end

  defp drain_log_events do
    receive do
      {:log_event, event} -> [event | drain_log_events()]
    after
      0 -> []
    end
  end

  defp message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp message({:report, _report}), do: nil
end
