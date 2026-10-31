defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed order rows.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  The report has two parts:

    * `:customers` - keyed by customer ID. Each entry has `:totals` (amount
      per currency, completed orders only), `:completed_count` and
      `:last_order_on` (the date of the customer's most recent order, any
      status).
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples, most
      completed orders first. Ties are broken by customer ID.
  """

  @top_n 5

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report from a list of order maps.

  Raises `Decimal.Error` if an amount is not a valid decimal string, and
  `MatchError` if a `placed_at` value is not a valid ISO 8601 datetime.
  """
  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    customers =
      Enum.reduce(orders, %{}, fn order, acc ->
        add_order(acc, parse_order(order))
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
    %{
      customer_id: customer_id,
      amount: Decimal.new(amount),
      currency: currency,
      date: parse_date(placed_at),
      status: status
    }
  end

  # Keeps the date as written in the order's own offset, so 23:30 at -05:00
  # stays on the same day instead of shifting to the next UTC day.
  defp parse_date(placed_at) do
    {:ok, datetime} = NaiveDateTime.from_iso8601(placed_at)
    NaiveDateTime.to_date(datetime)
  end

  defp add_order(customers, order) do
    customer =
      Map.get(customers, order.customer_id, %{
        totals: %{},
        completed_count: 0,
        last_order_on: order.date
      })

    Map.put(customers, order.customer_id, record(customer, order))
  end

  defp record(customer, order) do
    customer = %{customer | last_order_on: Enum.max([customer.last_order_on, order.date], Date)}

    if order.status == "completed" do
      %{
        customer
        | totals: Map.update(customer.totals, order.currency, order.amount, &Decimal.add(&1, order.amount)),
          completed_count: customer.completed_count + 1
      }
    else
      customer
    end
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_id, customer} -> customer.completed_count > 0 end)
    |> Enum.map(fn {id, customer} -> {id, customer.completed_count} end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end
end
