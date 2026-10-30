defmodule Reports.Orders do
  @moduledoc """
  Builds a report from a list of order maps (string keys, as produced by a CSV parser).

  Each order has "customer_id", "amount", "currency", "placed_at" (ISO 8601) and
  "status" ("completed", "refunded", "pending").
  """

  @top_n 5

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          completed_orders: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns `%{customers: ..., top_customers: ...}`.

  * `customers` maps each customer id to the total spent per currency across
    completed orders, the number of completed orders, and the date of the most
    recent order of any status.
  * `top_customers` is a list of `{customer_id, completed_orders}` for the top
    #{@top_n} customers, sorted by count descending, then customer id.

  Raises `ArgumentError` if an order has an invalid amount or datetime.
  """
  @spec build([map()]) :: t()
  def build(orders) do
    customers =
      orders
      |> Enum.group_by(& &1["customer_id"])
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, customer_report(customer_orders)}
      end)

    top_customers =
      customers
      |> Enum.map(fn {id, %{completed_orders: count}} -> {id, count} end)
      |> Enum.reject(fn {_id, count} -> count == 0 end)
      |> Enum.sort_by(fn {id, count} -> {-count, id} end)
      |> Enum.take(@top_n)

    %{customers: customers, top_customers: top_customers}
  end

  defp customer_report(orders) do
    completed = Enum.filter(orders, &(&1["status"] == "completed"))

    %{
      totals: totals_by_currency(completed),
      completed_orders: length(completed),
      last_order_on: last_order_date(orders)
    }
  end

  defp totals_by_currency(completed) do
    Enum.reduce(completed, %{}, fn order, acc ->
      amount = parse_amount!(order["amount"])
      Map.update(acc, order["currency"], amount, &Decimal.add(&1, amount))
    end)
  end

  defp last_order_date(orders) do
    orders
    |> Enum.map(&parse_datetime!(&1["placed_at"]))
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp parse_amount!(string) do
    case Decimal.parse(string) do
      {decimal, ""} -> decimal
      _ -> raise ArgumentError, "invalid amount: #{inspect(string)}"
    end
  end

  defp parse_datetime!(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(string)}: #{reason}"
    end
  end
end
