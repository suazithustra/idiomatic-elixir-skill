defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with string keys and string values:

      %{
        "customer_id" => "c-42",
        "amount" => "19.99",
        "currency" => "EUR",
        "placed_at" => "2024-05-01T10:15:00Z",
        "status" => "completed"
      }

  Amounts are parsed as `Decimal` so money is never rounded through floats.
  `placed_at` must carry a UTC offset (`Z` or `+02:00`); the reported date is
  the calendar date in UTC.
  """

  @top_customers 5

  @type row :: %{optional(String.t()) => String.t()}

  @type customer_summary :: %{
          total_spent: %{currency :: String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{customer_id :: String.t() => customer_summary()},
          top_customers: [%{customer_id: String.t(), completed_orders: pos_integer()}]
        }

  @type error :: {:invalid_order, index :: non_neg_integer(), reason :: term()}

  @doc """
  Builds the report.

    * `:customers` - for every customer, the total spent per currency over
      completed orders, and the date of their most recent order of any status.
      Customers with no completed orders have an empty `:total_spent` map.
    * `:top_customers` - up to #{@top_customers} customers with the most
      completed orders, most first. Ties are ordered by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, rather than producing totals that silently skip it.
  """
  @spec build([row()]) :: {:ok, report()} | {:error, error()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_all(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, orders} -> {customer_id, summarize(orders)} end)
  end

  defp summarize(orders) do
    %{total_spent: total_spent(orders), last_order_on: last_order_on(orders)}
  end

  defp total_spent(orders) do
    for %{status: :completed, currency: currency, amount: amount} <- orders, reduce: %{} do
      totals -> Map.update(totals, currency, amount, &Decimal.add(&1, amount))
    end
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers)
    |> Enum.map(fn {customer_id, count} -> %{customer_id: customer_id, completed_orders: count} end)
  end

  ## Parsing

  defp parse_all(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
  end

  defp parse(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_placed_at(placed_at),
         {:ok, status} <- parse_status(status) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse(_row), do: {:error, :missing_fields}

  defp parse_amount(string) do
    with {decimal, ""} <- Decimal.parse(string),
         true <- finite?(decimal) do
      {:ok, decimal}
    else
      _ -> {:error, {:invalid_amount, string}}
    end
  end

  defp finite?(decimal), do: not (Decimal.nan?(decimal) or Decimal.inf?(decimal))

  defp parse_placed_at(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_placed_at, string, reason}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(status), do: {:error, {:invalid_status, status}}
end
