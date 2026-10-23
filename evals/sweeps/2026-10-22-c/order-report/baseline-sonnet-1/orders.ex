defmodule Reports.Orders do
  @moduledoc """
  Builds a report from CSV-parsed order maps (string keys).

  The report has two parts:

    * `:customers` - a map of `customer_id => %{totals: %{currency => Decimal.t()},
      last_order_on: Date.t()}`. Totals only include completed orders; the last
      order date considers every order regardless of status.
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples, ordered
      by completed order count (descending), ties broken by customer id.
  """

  @top_n 5

  @type order :: %{optional(String.t()) => String.t()}
  @type report :: %{
          customers: %{
            String.t() => %{totals: %{String.t() => Decimal.t()}, last_order_on: Date.t()}
          },
          top_customers: [{String.t(), pos_integer()}]
        }

  @spec build([order()]) :: report()
  def build(orders) do
    customers = Enum.reduce(orders, %{}, &add_order/2)

    %{
      customers: Map.new(customers, fn {id, c} -> {id, Map.take(c, [:totals, :last_order_on])} end),
      top_customers: top_customers(customers)
    }
  end

  defp add_order(order, acc) do
    %{"customer_id" => id, "placed_at" => placed_at} = order
    placed_on = placed_at |> parse_datetime!() |> DateTime.to_date()

    Map.update(acc, id, new_customer(order, placed_on), fn customer ->
      customer
      |> Map.update!(:last_order_on, &latest(&1, placed_on))
      |> add_completed(order)
    end)
  end

  defp new_customer(order, placed_on) do
    add_completed(%{totals: %{}, completed: 0, last_order_on: placed_on}, order)
  end

  defp add_completed(customer, %{"status" => "completed", "amount" => amount, "currency" => cur}) do
    amount = Decimal.new(amount)

    customer
    |> Map.update!(:completed, &(&1 + 1))
    |> Map.update!(:totals, &Map.update(&1, cur, amount, fn sum -> Decimal.add(sum, amount) end))
  end

  defp add_completed(customer, _order), do: customer

  defp latest(a, b), do: if(Date.compare(a, b) == :lt, do: b, else: a)

  defp parse_datetime!(string) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(string)
    datetime
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed: n}} -> {id, n} end)
    |> Enum.filter(fn {_id, n} -> n > 0 end)
    |> Enum.sort_by(fn {id, n} -> {-n, id} end)
    |> Enum.take(@top_n)
  end
end
