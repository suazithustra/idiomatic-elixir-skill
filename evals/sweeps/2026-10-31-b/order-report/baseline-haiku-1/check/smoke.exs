defmodule DecimalStub do
  def run do
    Code.compile_file("/private/tmp/claude-501/-Users-suazi-Repos-idiomatic-elixir-skill/63fbd3f7-5995-424e-b268-7679cfbb08c1/scratchpad/sweep-2026-10-31-b-root/runs/order-report/baseline-haiku-1/check/decimal_stub.ex")
    Code.compile_file("/private/tmp/claude-501/-Users-suazi-Repos-idiomatic-elixir-skill/63fbd3f7-5995-424e-b268-7679cfbb08c1/scratchpad/sweep-2026-10-31-b-root/runs/order-report/baseline-haiku-1/orders.ex")

    orders = [
      order("a", "10.00", "EUR", "2026-01-02T10:00:00+01:00", "completed"),
      order("a", "5.50", "EUR", "2026-03-01T10:00:00Z", "completed"),
      order("a", "3.00", "USD", "2026-02-01T10:00:00Z", "refunded"),
      order("b", "1.00", "USD", "2026-02-01T10:00:00Z", "pending"),
      order("c", "2.00", "EUR", "2026-02-01T23:30:00-05:00", "completed")
    ]

    IO.inspect(Reports.Orders.build(orders), pretty: true)
  end

  defp order(id, amount, currency, placed_at, status) do
    %{
      "customer_id" => id,
      "amount" => amount,
      "currency" => currency,
      "placed_at" => placed_at,
      "status" => status
    }
  end
end

DecimalStub.run()
