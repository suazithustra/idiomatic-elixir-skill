defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime) and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, or `{:error, reason}` when a row is missing a field
  or has a value that cannot be read. The reason is `{:missing_field, key}` or
  `{:invalid_field, key}`.

  The report is a map with two keys:

    * `:customers` - a map from `customer_id` to a summary with `:totals`
      (completed spend per currency, as `Decimal`), `:completed_count`, and
      `:last_order_at` (the latest `placed_at` across all of the customer's
      orders, whatever their status)
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      highest count first, ties broken by `customer_id`
  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows, []) do
      {:ok, report(orders)}
    end
  end

  defp parse_rows([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_rows([row | rows], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_rows(rows, [order | orders])
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
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
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

  defp report(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    last_order_at =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{
      totals: totals_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_at: last_order_at
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} ->
      {customer_id, summary.completed_count}
    end)
    |> Enum.filter(fn {_customer_id, count} ->
      count > 0
    end)
    |> Enum.sort_by(fn {customer_id, count} ->
      {-count, customer_id}
    end)
    |> Enum.take(@top_count)
  end
end
