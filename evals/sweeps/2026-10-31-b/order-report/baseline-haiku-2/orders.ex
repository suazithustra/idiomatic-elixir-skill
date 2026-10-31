defmodule Reports.Orders do
  @moduledoc """
  Builds a report from order rows produced by a CSV parser.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string, such as `"19.99"`
    * `"currency"` - currency code, such as `"EUR"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Totals and the completed-order count only use orders with status
  `"completed"`. The most recent order date uses all orders, whatever
  their status.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t() | nil
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report for a list of order maps.

  `customers` maps each customer id to its summary. `top_customers` lists up
  to five `{customer_id, completed_count}` tuples, highest count first. Ties
  are ordered by customer id. Customers with no completed orders are left out
  of `top_customers`.
  """
  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    customers =
      Enum.reduce(orders, %{}, fn order, acc ->
        add_order(acc, parse_order(order))
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp parse_order(order) do
    %{
      customer_id: order["customer_id"],
      amount: Decimal.new(order["amount"]),
      currency: order["currency"],
      placed_on: parse_date(order["placed_at"]),
      status: order["status"]
    }
  end

  # Accepts datetimes with an offset (converted to UTC) and naive datetimes.
  defp parse_date(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} ->
        DateTime.to_date(datetime)

      {:error, :missing_offset} ->
        placed_at
        |> NaiveDateTime.from_iso8601!()
        |> NaiveDateTime.to_date()
    end
  end

  defp add_order(acc, order) do
    summary =
      acc
      |> Map.get(order.customer_id, empty_summary())
      |> update_last_order(order.placed_on)
      |> maybe_add_completed(order)

    Map.put(acc, order.customer_id, summary)
  end

  defp empty_summary do
    %{totals: %{}, completed_count: 0, last_order_on: nil}
  end

  defp update_last_order(summary, date) do
    %{summary | last_order_on: latest(summary.last_order_on, date)}
  end

  defp latest(nil, date), do: date

  defp latest(current, date) do
    if Date.compare(date, current) == :gt, do: date, else: current
  end

  defp maybe_add_completed(summary, %{status: "completed"} = order) do
    totals = Map.update(summary.totals, order.currency, order.amount, &Decimal.add(&1, order.amount))

    %{summary | totals: totals, completed_count: summary.completed_count + 1}
  end

  defp maybe_add_completed(summary, _order), do: summary

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
  end
end
