defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime with a UTC offset) and `"status"` (`"completed"`, `"refunded"` or
  `"pending"`).
  """

  @top_count 5

  @doc """
  Builds the report from a list of CSV rows.

  Returns `{:ok, report}` where `report` is a map with two keys:

    * `:customers` maps each customer id to `%{totals: totals, last_order_on: date}`.
      `totals` maps each currency to the sum of the customer's completed orders
      in that currency, as a `Decimal`. `last_order_on` is the date of the
      customer's most recent order, whatever its status, in UTC.
    * `:top_customers` lists up to five `{customer_id, count}` tuples, where
      `count` is the number of completed orders. Most orders first; ties go to
      the lower customer id.

  Returns `{:error, reason}` for the first row that cannot be parsed, such as
  `{:error, {:missing_field, "amount"}}` or `{:error, {:invalid_field, "placed_at"}}`.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}
  """
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, report(orders)}
    end
  end

  defp report(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(completed)
    }
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, customer_summary(customer_orders)}
    end)
  end

  defp customer_summary(orders) do
    %{
      totals: completed_totals(orders),
      last_order_on: last_order_on(orders)
    }
  end

  defp completed_totals(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(completed) do
    completed
    |> Enum.frequencies_by(& &1.customer_id)
    # Negating the count sorts the largest first; equal counts fall back to the id.
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
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
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
