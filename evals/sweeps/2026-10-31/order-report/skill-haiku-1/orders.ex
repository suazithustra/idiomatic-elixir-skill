defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from parsed order rows.

  Amounts are kept as integer minor units (cents), so sums are exact.
  """

  @top_count 5

  @doc """
  Builds the report from order rows with string keys, as a CSV parser returns them.

  Returns `{:ok, report}`, or `{:error, reason}` for the first malformed row.

  `report` has two keys:

    * `:customers` - a map from `customer_id` to `%{totals: totals, last_order_at: datetime}`.
      `totals` maps each currency to the sum of the customer's completed orders, in cents.
      `last_order_at` is the latest `placed_at` across all of the customer's orders,
      whatever their status.
    * `:top_customers` - up to five `{customer_id, count}` tuples, the customers with the
      most completed orders first. Ties are ordered by `customer_id`.
  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, %{customers: customer_summaries(orders), top_customers: top_customers(orders)}}
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

  defp parse_row(row) do
    with {:ok, customer_id} <- fetch_string(row, "customer_id"),
         {:ok, currency} <- fetch_string(row, "currency"),
         {:ok, amount_text} <- fetch_string(row, "amount"),
         {:ok, cents} <- parse_amount(amount_text),
         {:ok, placed_text} <- fetch_string(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_text),
         {:ok, status_text} <- fetch_string(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      order = %{
        customer_id: customer_id,
        currency: currency,
        cents: cents,
        placed_at: placed_at,
        status: status
      }

      {:ok, order}
    end
  end

  defp fetch_string(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) do
    case Regex.run(~r/\A(\d+)(?:\.(\d{1,2}))?\z/, text) do
      [_all, units] ->
        {:ok, String.to_integer(units) * 100}

      [_all, units, fraction] ->
        fraction_cents = String.to_integer(String.pad_trailing(fraction, 2, "0"))
        {:ok, String.to_integer(units) * 100 + fraction_cents}

      nil ->
        {:error, {:invalid_field, "amount"}}
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

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{totals: spent_by_currency(orders), last_order_at: latest.placed_at}
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, completed} -> {currency, Enum.sum_by(completed, & &1.cents)} end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
