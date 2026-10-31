defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows parsed out of a CSV file.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with an offset), and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Only completed orders count toward spending and the top-customer ranking.
  Every order, whatever its status, counts toward the most recent order date.
  """

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, where `report` has:

    * `:customers` - a map from `customer_id` to `%{spent: %{currency => Decimal.t()}, completed_orders: integer, last_order_on: Date.t()}`
    * `:top_customers` - up to five `{customer_id, completed_orders}` tuples, most completed orders first

  Returns `{:error, reason}` for the first row whose fields are missing or malformed.
  """
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(&summarize_entry/1)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_entry({customer_id, orders}), do: {customer_id, summarize_customer(orders)}

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &completed?/1)

    %{
      spent: spent_by_currency(completed),
      completed_orders: length(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp completed?(order), do: order.status == "completed"

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_orders > 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_orders, customer_id} end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_orders} end)
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | orders]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount_text,
         "currency" => currency,
         "placed_at" => placed_at_text,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_datetime(placed_at_text) do
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

  defp parse_order(_row), do: {:error, :invalid_order}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end
end
