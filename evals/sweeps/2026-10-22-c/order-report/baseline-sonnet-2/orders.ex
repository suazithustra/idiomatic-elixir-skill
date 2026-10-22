defmodule Reports.Orders do
  @moduledoc """
  Builds a report from a list of order maps (string keys, as produced by a CSV parser).

  Each order has "customer_id", "amount" (decimal string), "currency",
  "placed_at" (ISO 8601 datetime) and "status" ("completed", "refunded", "pending").
  """

  @top_n 5

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns a report with:

    * `:customers` - per customer, `:totals` (sum of completed orders per currency)
      and `:last_order_on` (date of the most recent order of any status)
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples, highest
      count first (ties broken by customer id)

  Raises if an order has a malformed amount or datetime.
  """
  @spec build([map()]) :: t()
  def build(orders) do
    orders = Enum.map(orders, &parse/1)

    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp parse(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    {:ok, placed_at, _offset} = DateTime.from_iso8601(placed_at)

    %{
      customer_id: customer_id,
      amount: Decimal.new(amount),
      currency: currency,
      placed_at: placed_at,
      status: status
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id,
       %{
         totals: totals(customer_orders),
         last_order_on: last_order_on(customer_orders)
       }}
    end)
  end

  defp totals(orders) do
    for %{status: "completed"} = order <- orders, reduce: %{} do
      acc -> Map.update(acc, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == "completed"))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
  end
end
