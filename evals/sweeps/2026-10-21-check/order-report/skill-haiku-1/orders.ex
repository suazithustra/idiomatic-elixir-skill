defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
  Malformed rows raise, so bad input fails at its source.
  """

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns a map with:

    * `:customers` - a map from `customer_id` to a summary with
      `:totals` (a map from currency to the sum of completed amounts as a
      `Decimal`), `:completed_count` (the number of completed orders), and
      `:last_order_date` (a `Date` in UTC, taken from all of the customer's
      orders regardless of status).
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples,
      highest count first. Ties are ordered by `customer_id`.
  """
  def build(orders) do
    customers =
      orders
      |> Enum.map(&parse_order/1)
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp parse_order(%{
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

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == "completed"))
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_date: DateTime.to_date(latest.placed_at)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_count > 0 end)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
