ExUnit.start()

defmodule Payments.LogForwarder do
  @moduledoc false
  # :logger handler that forwards every event to the test process, with its metadata intact.
  def log(%{level: level, msg: msg, meta: meta}, %{config: %{pid: pid}}) do
    send(pid, {:log, level, message(msg), meta})
  end

  defp message({:string, chardata}), do: IO.chardata_to_string(chardata)
  defp message({:report, report}), do: inspect(report)
  defp message({format, args}), do: format |> :io_lib.format(args) |> IO.chardata_to_string()
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger

  defmodule ApprovingGateway do
    @behaviour Payments.Gateway
    def charge(_amount, _token), do: {:ok, "ch_123"}
  end

  defmodule DecliningGateway do
    @behaviour Payments.Gateway
    def charge(_amount, _token), do: {:error, :declined}
  end

  defmodule DownGateway do
    @behaviour Payments.Gateway
    def charge(_amount, _token), do: {:error, :unavailable}
  end

  @severe [:warning, :error, :critical, :alert, :emergency]

  setup context do
    handler_id = :"log_forwarder_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler_id, Payments.LogForwarder, %{config: %{pid: self()}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)
    {:ok, request_id: "req-#{context.line}"}
  end

  # Events logged so far, as {level, message, metadata}.
  defp logged(acc \\ []) do
    receive do
      {:log, level, msg, meta} -> logged([{level, msg, meta} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp severe(events), do: Enum.filter(events, fn {level, _, _} -> level in @severe end)

  describe "successful charge" do
    test "returns the charge id", %{request_id: rid} do
      assert {:ok, "ch_123"} =
               Charger.charge(1_500, "tok", gateway: ApprovingGateway, request_id: rid)
    end

    test "logs nothing at warning level or above", %{request_id: rid} do
      Charger.charge(1_500, "tok", gateway: ApprovingGateway, request_id: rid)

      assert severe(logged()) == []
    end
  end

  describe "declined card" do
    test "returns the declined error", %{request_id: rid} do
      assert {:error, :declined} =
               Charger.charge(2_500, "tok", gateway: DecliningGateway, request_id: rid)
    end

    test "logs a warning carrying request id and amount in metadata", %{request_id: rid} do
      Charger.charge(2_500, "tok", gateway: DecliningGateway, request_id: rid)

      assert [{:warning, msg, meta}] = severe(logged())
      assert msg =~ "declined"
      assert meta[:request_id] == rid
      assert meta[:amount_cents] == 2_500
    end
  end

  describe "unavailable gateway" do
    test "returns the unavailable error", %{request_id: rid} do
      assert {:error, :unavailable} =
               Charger.charge(900, "tok", gateway: DownGateway, request_id: rid)
    end

    test "logs at error level", %{request_id: rid} do
      Charger.charge(900, "tok", gateway: DownGateway, request_id: rid)

      assert [{:error, msg, meta}] = severe(logged())
      assert msg =~ "unavailable"
      assert meta[:request_id] == rid
    end
  end
end
