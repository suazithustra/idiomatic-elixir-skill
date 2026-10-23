ExUnit.start()

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger

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

  # :logger handler callback; forwards each event to the test process.
  def log(event, %{config: %{test_pid: pid}}), do: send(pid, {:log_event, event})

  setup %{test: test} do
    handler_id = :"charger_test_#{test}"
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    :ok = :logger.add_handler(handler_id, __MODULE__, %{config: %{test_pid: self()}})

    on_exit(fn ->
      :logger.remove_handler(handler_id)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  defp events(acc) do
    receive do
      {:log_event, event} -> events([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp events, do: events([])

  defp opts(gateway), do: [gateway: gateway, request_id: "req-42"]

  test "a successful charge returns the charge id and logs nothing at warning or above" do
    assert {:ok, "ch_123"} = Charger.charge(1_500, "tok", opts(ApprovingGateway))

    logged = events()
    assert logged != []
    refute Enum.any?(logged, &(:logger.compare_levels(&1.level, :warning) in [:gt, :eq]))
  end

  test "a declined card returns the error and logs a warning with request id and amount" do
    assert {:error, :declined} = Charger.charge(2_500, "tok", opts(DecliningGateway))

    assert [%{level: :warning, meta: meta}] = events()
    assert meta.request_id == "req-42"
    assert meta.amount_cents == 2_500
  end

  test "an unavailable gateway returns the error and logs at error level" do
    assert {:error, :unavailable} = Charger.charge(900, "tok", opts(DownGateway))

    assert [%{level: :error, meta: meta}] = events()
    assert meta.request_id == "req-42"
    assert meta.amount_cents == 900
  end
end
