defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string, such as `"19.99"`
    * `"currency"` - currency code, such as `"EUR"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Rules:

    * Only `"completed"` orders count toward spend and completed-order totals.
    * The most recent order date considers every order, whatever its status.
    * Top customers are ranked by completed-order count, highest first. Ties are
      broken by customer ID. Customers with no completed orders are excluded.
  """

  @top_n 5

  @empty_customer %{spent: %{}, completed_orders: 0, last_placed_at: nil}

  @doc """
  Returns a report map with two keys:

    * `:customers` - `%{customer_id => %{spent: %{currency => Decimal.t()},
      completed_orders: non_neg_integer(), last_order_on: Date.t()}}`
    * `:top_customers` - up to 5 maps of `%{customer_id: id, completed_orders: n}`
  """
  @spec build([map()]) :: %{customers: map(), top_customers: [map()]}
  def build(orders) do
    accumulated =
      Enum.reduce(orders, %{}, fn order, acc ->
        customer = Map.get(acc, order["customer_id"], @empty_customer)
        Map.put(acc, order["customer_id"], add_order(customer, order))
      end)

    %{
      customers: Map.new(accumulated, fn {id, customer} -> {id, summarize(customer)} end),
      top_customers: top_customers(accumulated)
    }
  end

  defp add_order(customer, order) do
    placed_at = parse_datetime!(order["placed_at"])
    customer = %{customer | last_placed_at: latest(customer.last_placed_at, placed_at)}

    if order["status"] == "completed" do
      amount = Decimal.new(order["amount"])
      currency = order["currency"]

      %{
        customer
        | completed_orders: customer.completed_orders + 1,
          spent: Map.update(customer.spent, currency, amount, &Decimal.add(&1, amount))
      }
    else
      customer
    end
  end

  defp summarize(customer) do
    %{
      spent: customer.spent,
      completed_orders: customer.completed_orders,
      last_order_on: DateTime.to_date(customer.last_placed_at)
    }
  end

  defp top_customers(accumulated) do
    accumulated
    |> Enum.filter(fn {_id, customer} -> customer.completed_orders > 0 end)
    |> Enum.sort_by(fn {id, customer} -> {-customer.completed_orders, id} end)
    |> Enum.take(@top_n)
    |> Enum.map(fn {id, customer} ->
      %{customer_id: id, completed_orders: customer.completed_orders}
    end)
  end

  defp latest(nil, placed_at), do: placed_at

  defp latest(current, placed_at) do
    if DateTime.compare(placed_at, current) == :gt, do: placed_at, else: current
  end

  defp parse_datetime!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(value)}: #{reason}"
    end
  end
end
