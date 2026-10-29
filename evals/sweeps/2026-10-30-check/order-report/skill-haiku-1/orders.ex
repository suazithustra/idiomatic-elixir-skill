defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by the CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with an offset), and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
  """

  @top_size 5

  @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
  defstruct [:customer_id, :amount, :currency, :placed_at, :status]

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row with a
  missing or malformed field. The report is a map with two keys:

    * `:customers` - a map from `customer_id` to a summary with:
      * `:spent` - a map from currency to the `Decimal` total of the
        customer's completed orders in that currency
      * `:completed_count` - the number of completed orders
      * `:last_order_on` - the `Date` of the customer's most recent order,
        counting orders of every status
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first, ties broken by `customer_id`
  """
  @spec build([map()]) :: {:ok, map()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      spent: spent_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp spent_by_currency(completed) do
    completed
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

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, completed_count} -> completed_count > 0 end)
    |> Enum.sort_by(fn {customer_id, completed_count} -> {-completed_count, customer_id} end)
    |> Enum.take(@top_size)
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      order = %__MODULE__{
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
end
