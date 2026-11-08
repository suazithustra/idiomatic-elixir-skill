defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from order rows
  produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with an offset, such as `"2024-03-01T12:00:00Z"`), and `"status"`
  (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_count 5
  @new_customer %{totals: %{}, completed_count: 0, last_order_at: nil}

  @doc """
  Builds the report for a list of order rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row with a
  missing or malformed field.

  The report has two keys:

    * `:customers` maps each customer ID to `%{totals: ..., completed_count: ...,
      last_order_at: ...}`. `totals` is a `%{currency => Decimal}` summed over
      completed orders only. `last_order_at` is the latest `DateTime` across all
      of the customer's orders, whatever their status.
    * `:top_customers` lists up to five `{customer_id, completed_count}` tuples,
      most completed orders first. Ties are ordered by customer ID. Customers
      with no completed orders are left out.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}

  """
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = Enum.reduce(orders, %{}, &add_order/2)
      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.map(&parse_order/1)
    |> collect_orders()
  end

  defp collect_orders(results) do
    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, order} -> order end)}
      error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status} <- string_field(row, "status") do
      order = %{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_at: placed_at,
        status: status
      }

      {:ok, order}
    end
  end

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp add_order(order, customers) do
    customer =
      customers
      |> Map.get(order.customer_id, @new_customer)
      |> record_date(order.placed_at)
      |> record_completed(order)

    Map.put(customers, order.customer_id, customer)
  end

  defp record_date(customer, placed_at) do
    %{customer | last_order_at: later(customer.last_order_at, placed_at)}
  end

  defp later(nil, placed_at), do: placed_at

  defp later(current, placed_at) do
    if DateTime.after?(placed_at, current) do
      placed_at
    else
      current
    end
  end

  defp record_completed(customer, %{status: "completed"} = order) do
    totals = add_amount(customer.totals, order.currency, order.amount)
    %{customer | totals: totals, completed_count: customer.completed_count + 1}
  end

  defp record_completed(customer, _order), do: customer

  defp add_amount(totals, currency, amount) do
    Map.update(totals, currency, amount, &Decimal.add(&1, amount))
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_id, customer} -> customer.completed_count > 0 end)
    |> Enum.map(fn {id, customer} -> {id, customer.completed_count} end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_count)
  end
end
