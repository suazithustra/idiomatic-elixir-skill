defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from parsed CSV order rows.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (decimal string
  such as `"19.99"`), `"currency"`, `"placed_at"` (ISO 8601 datetime string), and
  `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_n 5

  @doc """
  Returns `%{customers: map, top_customers: list}`.

    * `customers` maps each `customer_id` to:
      * `:totals` - `%{currency => Decimal}`, summed over completed orders only
      * `:completed_count` - number of completed orders
      * `:last_order_at` - latest `DateTime` across all of the customer's orders, any status
    * `top_customers` - up to 5 `{customer_id, completed_count}` tuples, most completed
      orders first. Ties are broken by `customer_id`. Customers with no completed
      orders are left out.

  Raises `ArgumentError` if a `placed_at` value is not a valid datetime.
  """
  @spec build([map()]) :: %{customers: map(), top_customers: [{String.t(), pos_integer()}]}
  def build(orders) when is_list(orders) do
    customers =
      Enum.reduce(orders, %{}, fn order, acc ->
        customer = Map.get(acc, order["customer_id"], new_customer())
        Map.put(acc, order["customer_id"], add_order(customer, order))
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp new_customer do
    %{totals: %{}, completed_count: 0, last_order_at: nil}
  end

  defp add_order(customer, order) do
    placed_at = parse_datetime!(order["placed_at"])
    customer = %{customer | last_order_at: latest(customer.last_order_at, placed_at)}

    if order["status"] == "completed" do
      amount = Decimal.new(order["amount"])
      totals = Map.update(customer.totals, order["currency"], amount, &Decimal.add(&1, amount))

      %{customer | totals: totals, completed_count: customer.completed_count + 1}
    else
      customer
    end
  end

  defp latest(nil, datetime), do: datetime

  defp latest(current, datetime) do
    if DateTime.compare(datetime, current) == :gt, do: datetime, else: current
  end

  # Accepts datetimes with an offset ("2026-10-31T10:00:00Z") and without one
  # ("2026-10-31T10:00:00"), which are treated as UTC.
  defp parse_datetime!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(value)}: #{inspect(reason)}"
        end
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
