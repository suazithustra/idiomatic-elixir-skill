defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from CSV-parsed order maps.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

  @top_customers 5

  @type report :: %{
          customers: %{
            String.t() => %{
              totals: %{String.t() => Decimal.t()},
              last_order_on: Date.t()
            }
          },
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Returns a report with:

    * `:customers` - per customer, `:totals` (completed spend per currency) and
      `:last_order_on` (date of the most recent order of any status)
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples, by
      completed order count descending, ties broken by customer id

  Raises if an order has an unparseable amount or timestamp.
  """
  @spec build([map()]) :: report()
  def build(orders) do
    stats = Enum.reduce(orders, %{}, &add_order/2)

    customers =
      Map.new(stats, fn {id, stat} ->
        {id, %{totals: stat.totals, last_order_on: DateTime.to_date(stat.last_order_at)}}
      end)

    %{customers: customers, top_customers: top_customers(stats)}
  end

  defp add_order(order, acc) do
    %{"customer_id" => id, "placed_at" => placed_at} = order
    placed_at = parse_datetime!(placed_at)

    Map.update(acc, id, new_stat(order, placed_at), fn stat ->
      stat
      |> Map.update!(:last_order_at, &latest(&1, placed_at))
      |> add_completed(order)
    end)
  end

  defp new_stat(order, placed_at) do
    add_completed(%{totals: %{}, completed: 0, last_order_at: placed_at}, order)
  end

  defp add_completed(stat, %{"status" => "completed"} = order) do
    %{"amount" => amount, "currency" => currency} = order
    amount = Decimal.new(amount)

    %{
      stat
      | totals: Map.update(stat.totals, currency, amount, &Decimal.add(&1, amount)),
        completed: stat.completed + 1
    }
  end

  defp add_completed(stat, _order), do: stat

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp parse_datetime!(string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(string)
    datetime
  end

  defp top_customers(stats) do
    stats
    |> Enum.map(fn {id, %{completed: completed}} -> {id, completed} end)
    |> Enum.reject(fn {_id, completed} -> completed == 0 end)
    |> Enum.sort_by(fn {id, completed} -> {-completed, id} end)
    |> Enum.take(@top_customers)
  end
end
