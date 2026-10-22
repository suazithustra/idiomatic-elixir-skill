defmodule Reports.Orders do
  @moduledoc """
  Builds a report from CSV-parsed order maps (string keys).

  The report is a map with:

    * `:customers` - `%{customer_id => %{totals: %{currency => Decimal}, last_order_at: DateTime}}`.
      `totals` only counts completed orders; `last_order_at` is the latest
      `placed_at` across all of the customer's orders, whatever their status.
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples, ordered by
      count descending (ties broken by customer id).

  Raises on malformed amounts or datetimes.
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
    customers = Enum.reduce(orders, %{}, &add_order/2)

    %{
      customers: Map.new(customers, fn {id, c} -> {id, Map.take(c, [:totals, :last_order_at])} end),
      top_customers: top_customers(customers)
    }
  end

  defp add_order(order, customers) do
    %{"customer_id" => id, "placed_at" => placed_at} = order
    placed_at = parse_datetime!(placed_at)

    Map.update(customers, id, new_customer(order, placed_at), fn customer ->
      customer
      |> update_last_order(placed_at)
      |> add_completed(order)
    end)
  end

  defp new_customer(order, placed_at) do
    add_completed(%{totals: %{}, completed: 0, last_order_at: placed_at}, order)
  end

  defp update_last_order(customer, placed_at) do
    if DateTime.compare(placed_at, customer.last_order_at) == :gt do
      %{customer | last_order_at: placed_at}
    else
      customer
    end
  end

  defp add_completed(customer, %{"status" => "completed"} = order) do
    %{"amount" => amount, "currency" => currency} = order
    amount = Decimal.new(amount)

    %{
      customer
      | totals: Map.update(customer.totals, currency, amount, &Decimal.add(&1, amount)),
        completed: customer.completed + 1
    }
  end

  defp add_completed(customer, _order), do: customer

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed: completed}} -> {id, completed} end)
    |> Enum.reject(fn {_id, completed} -> completed == 0 end)
    |> Enum.sort_by(fn {id, completed} -> {-completed, id} end)
    |> Enum.take(@top_n)
  end

  defp parse_datetime!(string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(string)
    datetime
  end
end
