defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from CSV-parsed order maps.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (decimal
  string), `"currency"`, `"placed_at"` (ISO 8601 datetime) and `"status"`
  (`"completed"`, `"refunded"` or `"pending"`).

  The report contains:

    * `:customers` - for each customer, the total spent per currency across
      completed orders (`:spent`) and the date of their most recent order of
      any status (`:last_order_date`).
    * `:top_customers` - up to five `{customer_id, count}` tuples, ordered by
      number of completed orders, highest first. Ties are broken by
      `customer_id`.
  """

  @top_count 5

  @type order :: %{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: String.t()
        }

  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          last_order_date: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report for a list of raw order maps.

  Raises if a required field is missing, an amount is not a valid decimal, or
  a `placed_at` value is not an ISO 8601 datetime.
  """
  @spec build([map()]) :: report()
  def build(rows) do
    orders = Enum.map(rows, &parse_order/1)

    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp parse_order(row) do
    %{
      customer_id: Map.fetch!(row, "customer_id"),
      amount: Decimal.new(Map.fetch!(row, "amount")),
      currency: Map.fetch!(row, "currency"),
      placed_at: parse_datetime!(Map.fetch!(row, "placed_at")),
      status: Map.fetch!(row, "status")
    }
  end

  defp parse_datetime!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp summarize(orders) do
    %{
      spent: spent_per_currency(orders),
      last_order_date:
        orders
        |> Enum.map(& &1.placed_at)
        |> Enum.max(DateTime)
        |> DateTime.to_date()
    }
  end

  defp spent_per_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.reduce(%{}, fn order, totals ->
      Map.update(totals, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(%{status: status}), do: status == "completed"
end
