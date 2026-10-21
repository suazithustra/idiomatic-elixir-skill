defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from parsed CSV order rows.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string such as `"19.99"`
    * `"currency"` - currency code such as `"EUR"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are stored as integers in minor units (cents) so totals stay exact.
  Spend counts only `"completed"` orders. The last order date considers all
  orders, since the report asks for the most recent order, not the most recent
  completed one.
  """

  @top_n 5

  @type customer_summary :: %{
          spend: %{String.t() => integer()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns a report with a summary for every customer and the top customers
  by number of completed orders.

  Ties in `top_customers` are broken by customer ID, ascending.
  """
  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    customers =
      orders
      |> Enum.group_by(&Map.fetch!(&1, "customer_id"))
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{
      customers: customers,
      top_customers: top_customers(customers)
    }
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1["status"] == "completed"))

    spend =
      Enum.reduce(completed, %{}, fn order, acc ->
        cents = parse_amount(order["amount"])
        Map.update(acc, order["currency"], cents, &(&1 + cents))
      end)

    %{
      spend: spend,
      completed_count: length(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(&parse_datetime(&1["placed_at"]))
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
  end

  # Converts "19.99" to 1999. Accepts "19", "19.9" and "19.99", and a leading "-".
  defp parse_amount("-" <> rest), do: -parse_amount(rest)

  defp parse_amount(string) do
    case String.split(string, ".") do
      [whole] ->
        String.to_integer(whole) * 100

      [whole, fraction] when byte_size(fraction) in 1..2 ->
        String.to_integer(whole) * 100 +
          String.to_integer(String.pad_trailing(fraction, 2, "0"))

      _ ->
        raise ArgumentError, "invalid amount: #{inspect(string)}"
    end
  end

  defp parse_datetime(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(string)}: #{reason}"
    end
  end
end
