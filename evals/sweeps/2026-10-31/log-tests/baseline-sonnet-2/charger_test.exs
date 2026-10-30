ExUnit.start()

defmodule Payments.Charger.TestHandler do
  @moduledoc false
  # An Erlang :logger handler that forwards the events logged by the test process
  # (level, message and metadata) to that process as messages.

  def log(%{level: level, msg: msg, meta: meta}, %{config: %{test_pid: pid}}) do
    if meta[:pid] == pid do
      send(pid, {:log, level, IO.iodata_to_binary(format(msg)), meta})
    end

    :ok
  end

  defp format({:string, chardata}), do: chardata
  defp format({:report, report}), do: inspect(report)
  defp format({fmt, args}), do: :io_lib.format(fmt, args)
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Payments.Charger

  defmodule Approving do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:ok, "ch_123"}
  end

  defmodule Declining do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:error, :declined}
  end

  defmodule Down do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:error, :unavailable}
  end

  setup %{test: test} do
    handler_id = test
    :ok = :logger.add_handler(handler_id, Payments.Charger.TestHandler, %{config: %{test_pid: self()}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)
    :ok
  end

  defp charge(gateway, amount \\ 4200, request_id \\ "req-1") do
    Charger.charge(amount, "tok_visa", gateway: gateway, request_id: request_id)
  end

  describe "successful charge" do
    test "returns the charge id" do
      assert charge(Approving) == {:ok, "ch_123"}
    end

    test "logs the charge at info with the request id and charge id" do
      charge(Approving, 4200, "req-ok")

      assert_receive {:log, :info, "charged 4200 cents", meta}
      assert meta[:request_id] == "req-ok"
      assert meta[:charge_id] == "ch_123"
    end

    test "logs nothing at warning level or above" do
      charge(Approving)

      for level <- [:warning, :error, :critical, :alert, :emergency] do
        refute_received {:log, ^level, _, _}
      end
    end
  end

  describe "declined card" do
    test "returns the error" do
      assert charge(Declining) == {:error, :declined}
    end

    test "logs a warning whose metadata carries the request id and the amount" do
      charge(Declining, 1999, "req-declined")

      assert_receive {:log, :warning, "card declined", meta}
      assert meta[:request_id] == "req-declined"
      assert meta[:amount_cents] == 1999
    end

    test "does not log at error level" do
      charge(Declining)
      refute_received {:log, :error, _, _}
    end
  end

  describe "unavailable gateway" do
    test "returns the error" do
      assert charge(Down) == {:error, :unavailable}
    end

    test "logs at error level with the request id and the amount" do
      charge(Down, 750, "req-down")

      assert_receive {:log, :error, message, meta}
      assert message =~ "gateway unavailable"
      assert meta[:request_id] == "req-down"
      assert meta[:amount_cents] == 750
    end

    test "does not log a warning" do
      charge(Down)
      refute_received {:log, :warning, _, _}
    end
  end
end
