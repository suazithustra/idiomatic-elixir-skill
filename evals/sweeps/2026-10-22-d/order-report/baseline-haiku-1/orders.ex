defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from parsed order rows.

  Amounts are kept as integer minor units (cents) so totals are exact without
  depending on a decimal library. Only `"completed"` orders count towards spend
  and the completed-order ranking; the last order date considers every order.
  """

  @top_count 5

  @doc """
  Returns `%{customers: map, top_customers: list}`.

  `customers` maps each `customer_id` to `%{totals: %{currency => cents},
  completed_count: integer, last_order_on: Date}`. `top_customers` is a list of
  `{customer_id, completed_count}` tuples, most completed orders first.
  """
  def build(orders) do
    customers = Enum.reduce(orders, %{}, &accumulate/2)

    %{
      customers: customers,
      top_customers: top_customers(customers)
    }
  end

  defp accumulate(order, acc) do
    Map.update(acc, order["customer_id"], new_customer(order), &add_order(&1, order))
  end

  defp new_customer(order) do
    add_order(%{totals: %{}, completed_count: 0, last_order_on: nil}, order)
  end

  defp add_order(customer, order) do
    customer
    |> Map.update!(:last_order_on, &latest(&1, placed_on(order)))
    |> add_completed(order)
  end

  defp add_completed(customer, %{"status" => "completed"} = order) do
    cents = to_cents(order["amount"])

    %{
      customer
      | completed_count: customer.completed_count + 1,
        totals: Map.update(customer.totals, order["currency"], cents, &(&1 + cents))
    }
  end

  defp add_completed(customer, _order), do: customer

  defp latest(nil, date), do: date
  defp latest(current, date), do: Enum.max([current, date], Date)

  defp placed_on(%{"placed_at" => placed_at}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(placed_at)
    DateTime.to_date(datetime)
  end

  defp to_cents("-" <> amount), do: -to_cents(amount)

  defp to_cents(amount) do
    case String.split(amount, ".", parts: 2) do
      [whole] ->
        String.to_integer(whole) * 100

      [whole, fraction] when byte_size(fraction) in 1..2 ->
        String.to_integer(whole) * 100 +
          String.to_integer(String.pad_trailing(fraction, 2, "0"))
    end
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_id, customer} -> customer.completed_count > 0 end)
    |> Enum.sort_by(fn {id, customer} -> {-customer.completed_count, id} end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {id, customer} -> {id, customer.completed_count} end)
  end
end
