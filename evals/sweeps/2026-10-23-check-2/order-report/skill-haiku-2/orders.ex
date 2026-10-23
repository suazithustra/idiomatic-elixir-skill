defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).

  Totals and the completed-order count use only completed orders. The most
  recent order date uses every order, whatever its status.
  """

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, where `report` has:

    * `:customers` - a map from `customer_id` to `%{totals: totals, last_order_at: datetime}`.
      `totals` maps each currency to the `Decimal` sum of that customer's completed orders.
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples, most orders first.
      Ties are ordered by `customer_id`.

  Returns `{:error, reason}` for the first row that is missing a field or has an invalid value.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}

  """
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    parsed = Enum.map(rows, &parse_order/1)

    case Enum.find(parsed, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(parsed, fn {:ok, order} -> order end)}
      error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
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

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    %{customers: customers(orders), top_customers: top_customers(orders)}
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, customer_summary(customer_orders)}
    end)
  end

  defp customer_summary(orders) do
    %{totals: totals(orders), last_order_at: last_order_at(orders)}
  end

  defp totals(orders) do
    orders
    |> completed_orders()
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(orders) do
    orders
    |> completed_orders()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed_orders(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
