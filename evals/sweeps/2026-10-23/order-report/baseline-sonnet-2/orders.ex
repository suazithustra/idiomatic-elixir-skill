defmodule Reports.Orders do
  @moduledoc """
  Builds a report from parsed order maps.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

  @top_n 5

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Returns `%{customers: ..., top_customers: ...}`.

  * `customers` maps each customer id to `%{totals: %{currency => Decimal}, last_order_on: Date}`.
    Totals only count completed orders. `last_order_on` is the date of the
    customer's latest order of any status, in UTC.
  * `top_customers` is up to #{@top_n} `{customer_id, completed_count}` tuples,
    highest count first, ties broken by customer id.

  Raises on a malformed amount or timestamp.
  """
  @spec build([map()]) :: t()
  def build(orders) do
    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1["customer_id"])
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id,
       %{
         totals: totals(customer_orders),
         last_order_on: last_order_on(customer_orders)
       }}
    end)
  end

  defp totals(orders) do
    for %{"status" => "completed"} = order <- orders, reduce: %{} do
      acc -> Map.update(acc, order["currency"], amount(order), &Decimal.add(&1, amount(order)))
    end
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(&placed_at/1)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1["status"] == "completed"))
    |> Enum.frequencies_by(& &1["customer_id"])
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end

  defp amount(%{"amount" => amount}), do: Decimal.new(amount)

  defp placed_at(%{"placed_at" => placed_at}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(placed_at)
    datetime
  end
end
