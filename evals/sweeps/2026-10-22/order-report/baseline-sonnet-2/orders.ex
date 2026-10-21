defmodule Reports.Orders do
  @moduledoc """
  Builds a report from a list of order maps with string keys.

  The report is a map with two keys:

    * `:customers` - a map of `customer_id => %{totals: %{currency => Decimal}, last_order_at: DateTime}`.
      `totals` only counts completed orders. `last_order_at` is the latest
      `placed_at` across all of the customer's orders, whatever their status.
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples, highest
      count first, ties broken by customer id.

  Malformed amounts or timestamps raise.
  """

  @top_n 5

  @type report :: %{
          customers: %{
            String.t() => %{totals: %{String.t() => Decimal.t()}, last_order_at: DateTime.t()}
          },
          top_customers: [{String.t(), pos_integer()}]
        }

  @spec build([map()]) :: report()
  def build(orders) do
    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customer_summaries(orders) do
    Enum.reduce(orders, %{}, fn order, acc ->
      placed_at = parse_datetime!(order["placed_at"])

      Map.update(acc, order["customer_id"], new_summary(order, placed_at), fn summary ->
        summary
        |> add_spend(order)
        |> Map.update!(:last_order_at, &latest(&1, placed_at))
      end)
    end)
  end

  defp new_summary(order, placed_at) do
    add_spend(%{totals: %{}, last_order_at: placed_at}, order)
  end

  defp add_spend(summary, %{"status" => "completed", "currency" => currency, "amount" => amount}) do
    amount = Decimal.new(amount)
    update_in(summary.totals, &Map.update(&1, currency, amount, fn sum -> Decimal.add(sum, amount) end))
  end

  defp add_spend(summary, _order), do: summary

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1["status"] == "completed"))
    |> Enum.frequencies_by(& &1["customer_id"])
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp parse_datetime!(string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(string)
    datetime
  end
end
