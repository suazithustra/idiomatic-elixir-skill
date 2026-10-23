ExUnit.start()

defmodule Payments.ChargerTest.LogForwarder do
  @moduledoc false
  # An Erlang :logger handler that sends each log event to a test process,
  # so tests can inspect level, message and metadata.

  def log(event, %{config: %{test_pid: pid}}) do
    send(pid, {:log, event})
    :ok
  end
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

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

  defmodule DownGateway do
    @behaviour Payments.Gateway
    @impl true
    def charge(_amount, _token), do: {:error, :unavailable}
  end

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    :ok =
      :logger.add_handler(handler_id, LogForwarder, %{
        level: :all,
        config: %{test_pid: self()}
      })

    on_exit(fn ->
      :logger.remove_handler(handler_id)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  defp charge(gateway, amount, request_id) do
    Charger.charge(amount, "tok_abc", gateway: gateway, request_id: request_id)
  end

  defp collect_logs(acc \\ []) do
    receive do
      {:log, event} -> collect_logs([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @severe [:warning, :error, :critical, :alert, :emergency]

  describe "successful charge" do
    test "returns the charge id" do
      assert {:ok, "ch_123"} = charge(ApprovingGateway, 1_500, "req-ok")
    end

    test "logs nothing at warning level or above" do
      charge(ApprovingGateway, 1_500, "req-ok")

      logs = collect_logs()
      assert logs != []
      assert Enum.filter(logs, &(&1.level in @severe)) == []
    end
  end

  describe "declined card" do
    test "returns the declined error" do
      assert {:error, :declined} = charge(DecliningGateway, 2_500, "req-declined")
    end

    test "logs a warning with request id and amount in metadata" do
      charge(DecliningGateway, 2_500, "req-declined")

      assert [event] = Enum.filter(collect_logs(), &(&1.level == :warning))
      assert event.meta[:request_id] == "req-declined"
      assert event.meta[:amount_cents] == 2_500
    end
  end

  describe "unavailable gateway" do
    test "returns the unavailable error" do
      assert {:error, :unavailable} = charge(DownGateway, 900, "req-down")
    end

    test "logs at error level" do
      charge(DownGateway, 900, "req-down")

      assert [event] = Enum.filter(collect_logs(), &(&1.level == :error))
      assert event.meta[:request_id] == "req-down"
      assert event.meta[:amount_cents] == 900
    end
  end
end
