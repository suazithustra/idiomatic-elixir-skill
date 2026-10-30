ExUnit.start()

defmodule Payments.Charger.TestHandler do
  @moduledoc false
  # Erlang :logger handler that forwards every event to the test process, so tests can
  # inspect the level, message and full metadata of each log call.

  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule Payments.Charger.ApprovingGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.Charger.DecliningGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.Charger.UnavailableGateway do
  @moduledoc false
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Payments.Charger
  alias Payments.Charger.{ApprovingGateway, DecliningGateway, TestHandler, UnavailableGateway}

  @handler_id :charger_test_handler

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    Logger.reset_metadata([])

    :ok = :logger.add_handler(@handler_id, TestHandler, %{level: :all, config: %{pid: self()}})

    on_exit(fn ->
      :logger.remove_handler(@handler_id)
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  defp charge(gateway, amount_cents \\ 4_200, request_id \\ "req-abc") do
    Charger.charge(amount_cents, "tok_visa", gateway: gateway, request_id: request_id)
  end

  defp collect_events(acc \\ []) do
    receive do
      {:log_event, event} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp at_or_above_warning?(%{level: level}), do: level in [:warning, :error, :critical, :alert, :emergency]

  describe "charge/3 when the gateway approves" do
    test "returns the charge id" do
      assert {:ok, "ch_123"} = charge(ApprovingGateway)
    end

    test "logs nothing at warning level or above" do
      charge(ApprovingGateway)

      events = collect_events()
      assert events != []
      refute Enum.any?(events, &at_or_above_warning?/1)
    end

    test "logs the charge at info level with the request id" do
      charge(ApprovingGateway)

      assert [%{level: :info, meta: meta}] = collect_events()
      assert meta[:request_id] == "req-abc"
      assert meta[:charge_id] == "ch_123"
    end
  end

  describe "charge/3 when the card is declined" do
    test "returns the decline error" do
      assert {:error, :declined} = charge(DecliningGateway)
    end

    test "logs one warning whose metadata carries the request id and the amount" do
      charge(DecliningGateway, 1_999, "req-declined")

      assert [%{level: :warning, meta: meta}] = collect_events()
      assert meta[:request_id] == "req-declined"
      assert meta[:amount_cents] == 1_999
    end

    test "does not log at error level" do
      charge(DecliningGateway)

      refute Enum.any?(collect_events(), &(&1.level == :error))
    end
  end

  describe "charge/3 when the gateway is unavailable" do
    test "returns the unavailable error" do
      assert {:error, :unavailable} = charge(UnavailableGateway)
    end

    test "logs one error with the request id and the amount" do
      charge(UnavailableGateway, 750, "req-down")

      assert [%{level: :error, meta: meta}] = collect_events()
      assert meta[:request_id] == "req-down"
      assert meta[:amount_cents] == 750
    end
  end
end
