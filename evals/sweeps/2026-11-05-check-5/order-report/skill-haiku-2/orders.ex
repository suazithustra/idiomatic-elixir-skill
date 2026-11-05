defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from order rows.

  Each row is a map with string keys, as produced by a CSV parser:

    * `"customer_id"` - the customer's identifier
    * `"amount"` - a decimal string such as `"19.99"`
    * `"currency"` - a currency code such as `"EUR"`
    * `"placed_at"` - an ISO 8601 datetime with an offset, such as `"2026-03-01T09:30:00+01:00"`
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`
  """

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that cannot
  be parsed. The report has two keys:

    * `:customers` - a map from `customer_id` to `%{spent: spent, last_order_on: date}`.
      `spent` maps each currency to the total of the customer's completed orders
      in that currency, as a `Decimal`. `last_order_on` is the `Date` of the
      customer's most recent order, whatever its status.
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      highest count first. Ties are ordered by `customer_id`.

  ## Examples

      iex> {:ok, report} = Reports.Orders.build([])
      iex> report
      %{customers: %{}, top_customers: []}

  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_row(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_row(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_datetime(placed_at),
         {:ok, status} <- parse_status(status) do
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

  defp parse_row(row), do: {:error, {:invalid_row, row}}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_amount, text}}
      :error -> {:error, {:invalid_amount, text}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_placed_at, text}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, customer_summary(customer_orders)}
    end)
  end

  defp customer_summary(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      spent: spent_by_currency(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
