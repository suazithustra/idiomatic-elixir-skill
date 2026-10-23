defmodule Reports.Orders do
  @moduledoc """
  Builds per-customer spending summaries and a top-customers ranking from
  parsed order rows.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_n 5

  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report for a list of orders.

  `:customers` maps each customer id to:

    * `:spent` - total per currency across completed orders only
    * `:completed_count` - number of completed orders
    * `:last_order_on` - date of the customer's most recent order, of any status

  `:top_customers` lists up to five `{customer_id, completed_count}` tuples,
  highest count first, ties broken by customer id. Customers with no completed
  orders are left out.
  """
  @spec build([map()]) :: report()
  def build(orders) do
    customers =
      Enum.reduce(orders, %{}, fn order, acc ->
        customer = Map.get(acc, order["customer_id"], empty_customer())
        Map.put(acc, order["customer_id"], add_order(customer, order))
      end)

    top_customers =
      customers
      |> Enum.map(fn {customer_id, customer} -> {customer_id, customer.completed_count} end)
      |> Enum.reject(fn {_customer_id, count} -> count == 0 end)
      |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
      |> Enum.take(@top_n)

    %{customers: customers, top_customers: top_customers}
  end

  defp empty_customer do
    %{spent: %{}, completed_count: 0, last_order_on: nil}
  end

  defp add_order(customer, %{"status" => "completed"} = order) do
    %{
      customer
      | spent: add_spend(customer.spent, order),
        completed_count: customer.completed_count + 1
    }
    |> touch_last_order(order)
  end

  defp add_order(customer, order), do: touch_last_order(customer, order)

  defp add_spend(spent, %{"amount" => amount, "currency" => currency}) do
    value = Decimal.new(amount)
    Map.update(spent, currency, value, &Decimal.add(&1, value))
  end

  defp touch_last_order(customer, order) do
    placed_on = placed_on(order)

    last_order_on =
      if customer.last_order_on && Date.compare(customer.last_order_on, placed_on) == :gt,
        do: customer.last_order_on,
        else: placed_on

    %{customer | last_order_on: last_order_on}
  end

  defp placed_on(%{"placed_at" => placed_at}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(placed_at)
    DateTime.to_date(datetime)
  end
end
