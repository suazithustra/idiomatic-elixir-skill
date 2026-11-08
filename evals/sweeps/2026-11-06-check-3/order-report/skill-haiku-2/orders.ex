defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with a UTC offset), and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}` where `report` is a map with:

    * `:customers` - a map from customer ID to a summary with `:totals`
      (currency to `Decimal` sum of completed orders), `:last_order_on`
      (the `Date` of the customer's most recent order, of any status) and
      `:completed_count`.
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first. Ties are ordered by customer ID.

  Returns `{:error, :invalid_order}` for a row missing a required key, and
  `{:error, {:invalid_field, name}}` for a row whose amount, date or status
  is malformed.
  """
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_order(%{
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

  defp parse_order(_row), do: {:error, :invalid_order}

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
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(&summarize_customer/1)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer({customer_id, orders}) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    summary = %{
      totals: totals_by_currency(completed),
      last_order_on: last_order_date(orders),
      completed_count: length(completed)
    }

    {customer_id, summary}
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(&sum_amounts/1)
  end

  defp sum_amounts({currency, amounts}) do
    {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
  end

  defp last_order_date(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(&completed_count/1)
    |> Enum.filter(&has_completed?/1)
    |> Enum.sort_by(&ranking_key/1)
    |> Enum.take(@top_count)
  end

  defp completed_count({customer_id, summary}), do: {customer_id, summary.completed_count}

  defp has_completed?({_customer_id, count}), do: count > 0

  defp ranking_key({customer_id, count}), do: {-count, customer_id}
end
