ExUnit.start()
{:ok, _} = Application.ensure_all_started(:logger)

defmodule Payments.ChargerTest.Gateway do
  @moduledoc "Test double for `Payments.Gateway`. The token picks the outcome."
  @behaviour Payments.Gateway

  @impl true
  def charge(_amount_cents, "tok_ok"), do: {:ok, "ch_123"}
  def charge(_amount_cents, "tok_declined"), do: {:error, :declined}
  def charge(_amount_cents, "tok_down"), do: {:error, :unavailable}
end

defmodule Payments.ChargerTest.Forwarder do
  @moduledoc """
  Erlang `:logger` handler that sends each log event to the test process.
  """

  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log_event, event})
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger

  @warning_or_above [:warning, :error, :critical, :alert, :emergency]

  setup do
    handler_id = :"charger_test_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(handler_id, Payments.ChargerTest.Forwarder, %{
        config: %{pid: self()}
      })

    on_exit(fn -> :logger.remove_handler(handler_id) end)
    :ok
  end

  defp charge(token, amount_cents \\ 500) do
    Charger.charge(amount_cents, token,
      gateway: Payments.ChargerTest.Gateway,
      request_id: "req-42"
    )
  end

  defp message(%{msg: {:string, chardata}}), do: IO.iodata_to_binary(chardata)
  defp message(%{msg: {:report, report}}), do: inspect(report)
  defp message(%{msg: {format, args}}), do: IO.iodata_to_binary(:io_lib.format(format, args))

  defp received_events do
    receive do
      {:log_event, event} -> [event | received_events()]
    after
      0 -> []
    end
  end

  describe "successful charge" do
    test "returns the charge id" do
      assert {:ok, "ch_123"} = charge("tok_ok")
    end

    test "logs nothing at warning level or above" do
      charge("tok_ok")

      loud =
        received_events()
        |> Enum.filter(&(&1.level in @warning_or_above))

      assert loud == []
    end

    test "logs the charge at info level with the charge id" do
      charge("tok_ok", 1250)

      assert [%{level: :info} = event] = received_events()
      assert message(event) == "charged 1250 cents"
      assert event.meta.charge_id == "ch_123"
    end
  end

  describe "declined card" do
    test "returns the decline" do
      assert {:error, :declined} = charge("tok_declined")
    end

    test "logs a warning with the request id and amount in the metadata" do
      charge("tok_declined", 500)

      assert [event] = received_events()
      assert event.level == :warning
      assert message(event) == "card declined"
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 500
    end

    test "does not log at error level" do
      charge("tok_declined")

      errors = Enum.filter(received_events(), &(&1.level == :error))
      assert errors == []
    end
  end

  describe "unavailable gateway" do
    test "returns the unavailable error" do
      assert {:error, :unavailable} = charge("tok_down")
    end

    test "logs at error level with the request id and amount in the metadata" do
      charge("tok_down", 700)

      assert [event] = received_events()
      assert event.level == :error
      assert message(event) == "gateway unavailable, charge not attempted"
      assert event.meta.request_id == "req-42"
      assert event.meta.amount_cents == 700
    end
  end
end
