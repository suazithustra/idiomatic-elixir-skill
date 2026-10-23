defmodule Reports.Orders do
  @moduledoc """
  Builds a report from orders produced by the CSV parser.

  Each order is a map with string keys:

    * `"customer_id"`
    * `"amount"` - decimal string, e.g. `"19.99"`
    * `"currency"` - e.g. `"EUR"`, `"USD"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are handled with `Decimal` so no precision is lost to floats.
  """

  @top_customers_limit 5

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          totals: %{currency() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{customer_id() => customer_summary()},
          top_customers: [{customer_id(), non_neg_integer()}]
        }

  @doc """
  Builds the report.

    * `:customers` - per customer, the total spent per currency across
      completed orders, and the datetime of their most recent order
      (of any status). Customers with no completed orders have empty totals.
    * `:top_customers` - the top #{@top_customers_limit} customers by number
      of completed orders, as `{customer_id, count}` tuples, most first.
      Ties are broken by customer id so the result is deterministic.

  Raises `ArgumentError` on a malformed order.
  """
  @spec build([map()]) :: report()
  def build(raw_orders) when is_list(raw_orders) do
    orders = Enum.map(raw_orders, &parse!/1)

    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id,
       %{
         totals: totals_by_currency(customer_orders),
         last_order_at: customer_orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime)
       }}
    end)
  end

  defp totals_by_currency(orders) do
    for %{status: :completed} = order <- orders, reduce: %{} do
      totals -> Map.update(totals, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers_limit)
  end

  defp parse!(
         %{
           "customer_id" => customer_id,
           "amount" => amount,
           "currency" => currency,
           "placed_at" => placed_at,
           "status" => status
         } = order
       ) do
    %{
      customer_id: customer_id,
      amount: parse_amount!(amount, order),
      currency: currency,
      placed_at: parse_datetime!(placed_at, order),
      status: parse_status!(status, order)
    }
  end

  defp parse!(order) do
    raise ArgumentError, "order is missing required fields: #{inspect(order)}"
  end

  defp parse_amount!(amount, order) do
    case Decimal.parse(amount) do
      {decimal, ""} -> decimal
      _ -> raise ArgumentError, "invalid amount #{inspect(amount)} in order #{inspect(order)}"
    end
  end

  defp parse_datetime!(placed_at, order) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise ArgumentError,
              "invalid placed_at #{inspect(placed_at)} (#{reason}) in order #{inspect(order)}"
    end
  end

  defp parse_status!("completed", _order), do: :completed
  defp parse_status!("refunded", _order), do: :refunded
  defp parse_status!("pending", _order), do: :pending

  defp parse_status!(status, order) do
    raise ArgumentError, "unknown status #{inspect(status)} in order #{inspect(order)}"
  end
end
