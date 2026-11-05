defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_size 5

  @doc """
  Builds the report for a list of CSV rows.

  Returns `{:ok, report}`, where `report` has:

    * `:customers` - a map from customer ID to a map with `:totals` (the sum of
      completed amounts per currency, as `Decimal`), `:completed_orders` (the
      number of completed orders) and `:last_order_date` (the date of the
      customer's most recent order of any status, in UTC).
    * `:top_customers` - up to five `%{customer_id: id, completed_orders: count}`
      maps, most completed orders first, ties broken by customer ID.

  Returns `{:error, {:invalid_row, row_number, reason}}` for the first row that
  cannot be parsed. `row_number` counts data rows from 1.
  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      report = %{
        customers: summarize_customers(orders),
        top_customers: top_customers(orders)
      }

      {:ok, report}
    end
  end

  defp parse_rows(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, row_number}, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | orders]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_row, row_number, reason}}}
      end
    end)
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_text),
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
      {:ok, value} -> {:ok, value}
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

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, rows} -> {customer_id, summarize_customer(rows)} end)
  end

  defp summarize_customer(orders) do
    %{
      totals: totals_by_currency(orders),
      completed_orders: Enum.count(orders, &completed?/1),
      last_order_date: last_order_date(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_date(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_size)
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end

  defp completed?(order), do: order.status == :completed
end
