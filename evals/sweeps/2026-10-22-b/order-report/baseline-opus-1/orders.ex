defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders produced by the CSV parser.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string, e.g. `"19.99"`
    * `"currency"` - ISO currency code, e.g. `"EUR"`
    * `"placed_at"` - ISO 8601 datetime with offset, e.g. `"2024-05-01T10:00:00Z"`
    * `"status"` - one of `"completed"`, `"refunded"`, `"pending"`

  Amounts are handled with `Decimal` so money is never rounded through floats.
  """

  @top_customers_limit 5

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          totals: %{currency => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{customer_id => customer_summary},
          top_customers: [{customer_id, pos_integer()}]
        }

  @doc """
  Builds the report.

  Returns a map with:

    * `:customers` - per customer, the total spent per currency across
      completed orders (`:totals`) and the date of their most recent order
      of any status (`:last_order_on`)
    * `:top_customers` - up to #{@top_customers_limit} `{customer_id, count}`
      tuples ordered by number of completed orders, descending; ties are
      broken by customer id so the result is deterministic

  Raises `ArgumentError` if an order is missing fields or has an invalid
  status or datetime, and `Decimal.Error` if an amount is not a valid decimal.
  """
  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    orders = Enum.map(orders, &parse_order/1)

    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders, @top_customers_limit)
    }
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{
      totals: completed_totals(orders),
      last_order_on: orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime) |> DateTime.to_date()
    }
  end

  defp completed_totals(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders, limit) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(limit)
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    %{
      customer_id: customer_id,
      amount: Decimal.new(amount),
      currency: currency,
      placed_at: parse_datetime!(placed_at),
      status: parse_status!(status)
    }
  end

  defp parse_order(order) do
    raise ArgumentError, "order is missing required fields: #{inspect(order)}"
  end

  defp parse_datetime!(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise ArgumentError, "invalid placed_at #{inspect(string)}: #{reason}"
    end
  end

  defp parse_status!("completed"), do: :completed
  defp parse_status!("refunded"), do: :refunded
  defp parse_status!("pending"), do: :pending

  defp parse_status!(status) do
    raise ArgumentError, "unknown order status: #{inspect(status)}"
  end
end
