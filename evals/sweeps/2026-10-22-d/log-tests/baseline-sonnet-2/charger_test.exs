ExUnit.start()

defmodule Payments.Charger.TestHandler do
  @moduledoc false
  # :logger handler that forwards every event to the test process named in the handler config.
  def log(event, %{config: %{test_pid: pid}}), do: send(pid, {:log, event})
end

defmodule Payments.ChargerTest do
  use ExUnit.Case, async: false

  alias Payments.Charger

  defmodule Approving do
    @behaviour Payments.Gateway
    def charge(_amount, _token), do: {:ok, "ch_123"}
  end

  defmodule Declining do
    @behaviour Payments.Gateway
    def charge(_amount, _token), do: {:error, :declined}
  end

  defmodule Down do
    @behaviour Payments.Gateway
    def charge(_amount, _token), do: {:error, :unavailable}
  end

  setup do
    id = :"charger_test_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(id, Payments.Charger.TestHandler, %{
        level: :all,
        config: %{test_pid: self()}
      })

    on_exit(fn -> :logger.remove_handler(id) end)
    :ok
  end

  # Events logged by the calling process, drained from the mailbox.
  defp events(acc \\ []) do
    receive do
      {:log, %{meta: %{pid: pid}} = event} when pid == self() -> events([event | acc])
      {:log, _other} -> events(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp charge(gateway), do: Charger.charge(1250, "tok_abc", gateway: gateway, request_id: "req-42")

  test "a successful charge returns the charge id" do
    assert {:ok, "ch_123"} = charge(Approving)
  end

  test "a successful charge logs nothing at warning level or above" do
    charge(Approving)

    severe = Enum.filter(events(), &(&1.level in [:warning, :error, :critical, :alert, :emergency]))
    assert severe == []
  end

  test "a declined card returns the error" do
    assert {:error, :declined} = charge(Declining)
  end

  test "a declined card logs a warning carrying the request id and the amount" do
    charge(Declining)

    assert [%{level: :warning, meta: meta}] = events()
    assert meta.request_id == "req-42"
    assert meta.amount_cents == 1250
  end

  test "an unavailable gateway returns the error" do
    assert {:error, :unavailable} = charge(Down)
  end

  test "an unavailable gateway logs at error level" do
    charge(Down)

    assert [%{level: :error, meta: meta}] = events()
    assert meta.request_id == "req-42"
    assert meta.amount_cents == 1250
  end
end
