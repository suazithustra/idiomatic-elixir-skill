ExUnit.start()

defmodule Payments.ChargerTest.Approving do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.ChargerTest.Declining do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.ChargerTest.Unavailable do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest.LogForwarder do
  # A :logger handler that hands each event from the test process to the test.
  def log(event, %{test_pid: test_pid}) do
    if Map.get(event.meta, :pid) == test_pid, do: send(test_pid, {:log, event})
  end
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Payments.ChargerTest.{Approving, Declining, LogForwarder, Unavailable}

  @levels_at_or_above_warning [:warning, :error, :critical, :alert, :emergency]

  setup do
    handler = :"charger_test_log_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler, LogForwarder, %{level: :all, test_pid: self()})
    on_exit(fn -> :logger.remove_handler(handler) end)
    :ok
  end

  defp charge(gateway, amount_cents, request_id) do
    {result, _console} =
      with_log(fn ->
        Payments.Charger.charge(amount_cents, "tok_test",
          gateway: gateway,
          request_id: request_id
        )
      end)

    result
  end

  # Every log event the test process emitted so far, in order.
  defp collect_logs do
    receive do
      {:log, event} -> [event | collect_logs()]
    after
      0 -> []
    end
  end

  test "a successful charge returns the charge id" do
    assert {:ok, "ch_123"} = charge(Approving, 1_500, "req-1")
  end

  test "a successful charge logs nothing at warning or above" do
    charge(Approving, 1_500, "req-1")

    noisy = Enum.filter(collect_logs(), &(&1.level in @levels_at_or_above_warning))
    assert noisy == []
  end

  test "a successful charge logs the charge id at info" do
    charge(Approving, 1_500, "req-1")

    assert [event] = Enum.filter(collect_logs(), &(&1.level == :info))
    assert event.meta.charge_id == "ch_123"
    assert event.meta.request_id == "req-1"
  end

  test "a declined card returns the decline" do
    assert {:error, :declined} = charge(Declining, 1_500, "req-2")
  end

  test "a declined card logs one warning carrying the request id and amount" do
    charge(Declining, 1_500, "req-2")

    assert [event] = Enum.filter(collect_logs(), &(&1.level == :warning))
    assert event.meta.request_id == "req-2"
    assert event.meta.amount_cents == 1_500
  end

  test "an unavailable gateway returns the unavailable error" do
    assert {:error, :unavailable} = charge(Unavailable, 1_500, "req-3")
  end

  test "an unavailable gateway logs one error carrying the request id and amount" do
    charge(Unavailable, 1_500, "req-3")

    assert [event] = Enum.filter(collect_logs(), &(&1.level == :error))
    assert event.meta.request_id == "req-3"
    assert event.meta.amount_cents == 1_500
  end
end
