defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from parsed order rows.

  Each order is a map with string keys: "customer_id", "amount" (decimal
  string), "currency", "placed_at" (ISO 8601 datetime), and "status".

  Spend totals and the top-customer ranking count only "completed" orders.
  The last order date considers every order, whatever its status.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns a report with a summary per customer and the top customers by
  number of completed orders. Ties are broken by customer id.
  """
  @spec build([map()]) :: report()
  def build(orders) do
    customers =
      orders
      |> Enum.group_by(& &1["customer_id"])
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1["status"] == "completed"))

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_at: orders |> Enum.map(&placed_at/1) |> Enum.max(DateTime)
    }
  end

  defp totals_by_currency(orders) do
    Enum.reduce(orders, %{}, fn order, acc ->
      amount = Decimal.new(order["amount"])
      Map.update(acc, order["currency"], amount, &Decimal.add(&1, amount))
    end)
  end

  defp placed_at(order) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(order["placed_at"])
    datetime
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
  end
end
