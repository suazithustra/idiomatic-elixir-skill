ExUnit.start()

defmodule Payments.ChargerTest.LogCollector do
  # Erlang :logger handler that forwards each log event to the test process.
  # ExUnit.CaptureLog only returns formatted text, so it cannot show metadata.
  def log(event, %{pid: pid}), do: send(pid, {:log_event, event})
end

defmodule Payments.ChargerTest.ApprovedGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:ok, "ch_123"}
end

defmodule Payments.ChargerTest.DeclinedGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :declined}
end

defmodule Payments.ChargerTest.UnavailableGateway do
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, _token), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger
  alias Payments.ChargerTest.{ApprovedGateway, DeclinedGateway, LogCollector, UnavailableGateway}

  @warning_or_above [:warning, :error, :critical, :alert, :emergency]

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler_id, LogCollector, %{pid: self()})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    # Logger metadata lives in the process dictionary, so reset it between tests.
    Logger.reset_metadata()
    :ok
  end

  describe "charge/3 with an approved card" do
    test "returns the charge id" do
      assert {:ok, "ch_123"} =
               Charger.charge(500, "tok_visa",
                 gateway: ApprovedGateway,
                 request_id: "req-1"
               )
    end

    test "logs nothing at warning level or above" do
      Charger.charge(500, "tok_visa", gateway: ApprovedGateway, request_id: "req-1")

      assert warning_events() == []
    end

    test "logs the charge at info level" do
      Charger.charge(500, "tok_visa", gateway: ApprovedGateway, request_id: "req-1")

      assert_received {:log_event, %{level: :info, meta: meta}}
      assert meta[:charge_id] == "ch_123"
      assert meta[:request_id] == "req-1"
    end
  end

  describe "charge/3 with a declined card" do
    test "returns the declined error" do
      assert {:error, :declined} =
               Charger.charge(500, "tok_bad",
                 gateway: DeclinedGateway,
                 request_id: "req-2"
               )
    end

    test "logs a warning carrying the request id and the amount" do
      Charger.charge(750, "tok_bad", gateway: DeclinedGateway, request_id: "req-2")

      assert_received {:log_event, %{level: :warning, meta: meta} = event}
      assert message(event) =~ "card declined"
      assert meta[:request_id] == "req-2"
      assert meta[:amount_cents] == 750
    end

    test "logs exactly one event at warning level or above" do
      Charger.charge(750, "tok_bad", gateway: DeclinedGateway, request_id: "req-2")

      assert [%{level: :warning}] = warning_events()
    end
  end

  describe "charge/3 with an unavailable gateway" do
    test "returns the unavailable error" do
      assert {:error, :unavailable} =
               Charger.charge(900, "tok_any",
                 gateway: UnavailableGateway,
                 request_id: "req-3"
               )
    end

    test "logs at error level with the amount" do
      Charger.charge(900, "tok_any", gateway: UnavailableGateway, request_id: "req-3")

      assert_received {:log_event, %{level: :error, meta: meta} = event}
      assert message(event) =~ "gateway unavailable"
      assert meta[:amount_cents] == 900
      assert meta[:request_id] == "req-3"
    end

    test "does not log at warning level" do
      Charger.charge(900, "tok_any", gateway: UnavailableGateway, request_id: "req-3")

      assert [%{level: :error}] = warning_events()
    end
  end

  # Drains every log event sent to this process and returns those at warning or above.
  defp warning_events do
    receive do
      {:log_event, %{level: level} = event} when level in @warning_or_above ->
        [event | warning_events()]

      {:log_event, _other} ->
        warning_events()
    after
      0 -> []
    end
  end

  # Returns the text of a log event, whichever message form Logger used.
  defp message(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)

  defp message(%{msg: {:format, format, args}}),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp message(%{msg: {:report, report}}), do: inspect(report)
end
