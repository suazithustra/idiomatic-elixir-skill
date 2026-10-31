defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Every customer in the input
  appears in the report, whatever the status of their orders:

    * `total_spent` sums completed orders per currency as `Decimal`s. It is an
      empty map for a customer with no completed orders.
    * `last_order_date` is the UTC date of the customer's most recent order of
      any status.

  `top_customers` lists up to five customers with at least one completed order,
  most completed orders first. Ties are broken by customer ID so the result does
  not depend on input order.

  An invalid order fails the whole report, because leaving it out would
  understate the totals. `"placed_at"` must include a UTC offset, since orders
  cannot be put in sequence without one.
  """

  @top_customer_count 5

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          total_spent: %{currency() => Decimal.t()},
          last_order_date: Date.t()
        }

  @type top_customer :: %{customer_id: customer_id(), completed_orders: pos_integer()}

  @type report :: %{
          customers: %{customer_id() => customer_summary()},
          top_customers: [top_customer()]
        }

  @type invalid_reason ::
          :invalid_customer_id
          | :invalid_currency
          | :invalid_status
          | :invalid_amount
          | :invalid_placed_at

  @doc """
  Builds the report for `orders`.

  Returns `{:error, invalid_orders}` if any order is invalid, listing every
  invalid order with the reason it was rejected.

  ## Examples

      iex> Reports.Orders.build([
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ])
      {:ok,
       %{
         customers: %{
           "c1" => %{
             total_spent: %{"EUR" => Decimal.new("19.99")},
             last_order_date: ~D[2024-03-01]
           }
         },
         top_customers: [%{customer_id: "c1", completed_orders: 1}]
       }}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, [{map(), invalid_reason()}]}
  def build(orders) when is_list(orders) do
    with {:ok, parsed} <- parse_orders(orders) do
      {:ok, %{customers: customers(parsed), top_customers: top_customers(parsed)}}
    end
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      summary = %{
        total_spent: total_spent(customer_orders),
        last_order_date: last_order_date(customer_orders)
      }

      {customer_id, summary}
    end)
  end

  defp total_spent(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.reduce(%{}, fn %{currency: currency, amount: amount}, totals ->
      Map.update(totals, currency, amount, &Decimal.add(&1, amount))
    end)
  end

  defp last_order_date(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end

  defp completed?(order), do: order.status == :completed

  defp parse_orders(orders) do
    results = Enum.map(orders, &parse_order/1)

    case for {:error, invalid} <- results, do: invalid do
      [] -> {:ok, for({:ok, order} <- results, do: order)}
      invalid_orders -> {:error, invalid_orders}
    end
  end

  defp parse_order(order) do
    with {:ok, customer_id} <- parse_text(order["customer_id"], :invalid_customer_id),
         {:ok, currency} <- parse_text(order["currency"], :invalid_currency),
         {:ok, status} <- parse_status(order["status"]),
         {:ok, amount} <- parse_amount(order["amount"]),
         {:ok, placed_at} <- parse_placed_at(order["placed_at"]) do
      {:ok,
       %{
         customer_id: customer_id,
         currency: currency,
         status: status,
         amount: amount,
         placed_at: placed_at
       }}
    else
      {:error, reason} -> {:error, {order, reason}}
    end
  end

  defp parse_text(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp parse_text(_value, reason), do: {:error, reason}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_status), do: {:error, :invalid_status}

  # Decimal.parse/1 also accepts "NaN" and "Infinity", which would corrupt the totals.
  defp parse_amount(amount) when is_binary(amount) do
    with {decimal, ""} <- Decimal.parse(amount),
         false <- Decimal.nan?(decimal) or Decimal.inf?(decimal) do
      {:ok, decimal}
    else
      _other -> {:error, :invalid_amount}
    end
  end

  defp parse_amount(_amount), do: {:error, :invalid_amount}

  defp parse_placed_at(placed_at) when is_binary(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_placed_at}
    end
  end

  defp parse_placed_at(_placed_at), do: {:error, :invalid_placed_at}
end
