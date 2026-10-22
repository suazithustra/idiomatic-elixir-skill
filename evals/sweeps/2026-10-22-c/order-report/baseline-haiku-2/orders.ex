defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by the CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  The report has two parts:

    * `:customers` - per customer, `:totals` is the amount spent per currency
      across completed orders, and `:last_order_on` is the UTC date of the
      customer's most recent order, whatever its status.
    * `:top_customers` - up to five `{customer_id, count}` tuples for the
      customers with the most completed orders, highest count first. Ties are
      broken by customer id.
  """

  @top_count 5

  @spec build([map()]) :: %{
          customers: %{String.t() => %{totals: %{String.t() => Decimal.t()}, last_order_on: Date.t()}},
          top_customers: [{String.t(), non_neg_integer()}]
        }
  def build(rows) do
    orders = Enum.map(rows, &parse_order/1)

    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
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
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, :missing_offset} ->
        value
        |> NaiveDateTime.from_iso8601!()
        |> DateTime.from_naive!("Etc/UTC")
    end
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
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(%{status: "completed"}), do: true
  defp completed?(_order), do: false
end
