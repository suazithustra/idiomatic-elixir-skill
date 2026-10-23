ExUnit.start()
{:ok, _} = Application.ensure_all_started(:logger)

defmodule Payments.ChargerTest.StubGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  # Returns whatever the test put under :stub_result in the process dictionary.
  # Charger runs in the test process, so the test controls the outcome.
  @impl true
  def charge(_amount_cents, _token), do: Process.get(:stub_result)
end

defmodule Payments.ChargerTest.Capture do
  @moduledoc false
  # An Erlang :logger handler that forwards every log event to the test process.
  # Unlike ExUnit.CaptureLog, the event keeps its metadata map, so tests can check it.

  def log(event, %{test_pid: pid}), do: send(pid, {:log_event, event})
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  @handler_id :charger_test_capture
  @warning_or_above [:warning, :error, :critical, :alert, :emergency]
  @amount 2_500
  @request_id "req-test-42"

  setup do
    :ok = :logger.add_handler(@handler_id, Payments.ChargerTest.Capture, %{test_pid: self()})
    on_exit(fn -> :logger.remove_handler(@handler_id) end)

    :ok
  end

  describe "declined card" do
    test "returns the error" do
      Process.put(:stub_result, {:error, :declined})

      assert {:error, :declined} = charge()
    end

    test "logs a warning with the request id and amount in the metadata" do
      Process.put(:stub_result, {:error, :declined})

      charge()

      event = assert_log_event(:warning, "card declined")
      assert event.meta.request_id == @request_id
      assert event.meta.amount_cents == @amount
    end
  end

  describe "unavailable gateway" do
    test "returns the error" do
      Process.put(:stub_result, {:error, :unavailable})

      assert {:error, :unavailable} = charge()
    end

    test "logs at error level with the request id and amount in the metadata" do
      Process.put(:stub_result, {:error, :unavailable})

      charge()

      event = assert_log_event(:error, "gateway unavailable, charge not attempted")
      assert event.meta.request_id == @request_id
      assert event.meta.amount_cents == @amount
    end
  end

  describe "successful charge" do
    test "returns the charge id" do
      Process.put(:stub_result, {:ok, "ch_123"})

      assert {:ok, "ch_123"} = charge()
    end

    test "logs nothing at warning level or above" do
      Process.put(:stub_result, {:ok, "ch_123"})

      charge()

      refute_warning_or_above_logged()
    end
  end

  defp charge do
    Payments.Charger.charge(@amount, "tok_test",
      gateway: Payments.ChargerTest.StubGateway,
      request_id: @request_id
    )
  end

  # Waits for a log event at `level` whose message starts with `message`, then returns it.
  defp assert_log_event(level, message) do
    assert_receive {:log_event, %{level: ^level, msg: msg} = event}, 1_000
    assert message_text(msg) =~ message
    event
  end

  # refute_received does not take guards, so drain the mailbox and check each level.
  defp refute_warning_or_above_logged do
    receive do
      {:log_event, %{level: level, msg: msg}} when level in @warning_or_above ->
        flunk("expected no #{level} log, got: #{message_text(msg)}")

      {:log_event, _below_warning} ->
        refute_warning_or_above_logged()
    after
      0 -> :ok
    end
  end

  defp message_text({:string, iodata}), do: IO.iodata_to_binary(iodata)
  defp message_text({:report, report}), do: inspect(report)
  defp message_text({fmt, args}), do: :io_lib.format(fmt, args) |> IO.iodata_to_binary()
end
