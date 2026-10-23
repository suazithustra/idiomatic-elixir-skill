defmodule Reports.Orders do
  @moduledoc """
  Builds a report from a list of orders as produced by a CSV parser.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.

  The report has two parts:

    * `:customers` - a map of customer id to
      `%{totals: %{currency => Decimal.t()}, last_order_on: Date.t()}`.
      Totals only include completed orders. `last_order_on` considers orders
      of every status and is the UTC date of the latest `placed_at`.
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      ordered by count descending, then customer id ascending.

  Malformed amounts or timestamps raise.
  """

  @top_n 5

  @type order :: %{String.t() => String.t()}
  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }
  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @spec build([order()]) :: t()
  def build(orders) do
    customers = Enum.group_by(orders, & &1["customer_id"])

    %{
      customers: Map.new(customers, fn {id, rows} -> {id, customer_report(rows)} end),
      top_customers: top_customers(customers)
    }
  end

  defp customer_report(orders) do
    %{
      totals: totals_by_currency(orders),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.reduce(%{}, fn %{"amount" => amount, "currency" => currency}, acc ->
      Map.update(acc, currency, Decimal.new(amount), &Decimal.add(&1, Decimal.new(amount)))
    end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(&placed_at!/1)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, rows} -> {id, Enum.count(rows, &completed?/1)} end)
    |> Enum.reject(fn {_id, count} -> count == 0 end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end

  defp completed?(%{"status" => status}), do: status == "completed"

  defp placed_at!(%{"placed_at" => placed_at}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(placed_at)
    datetime
  end
end
