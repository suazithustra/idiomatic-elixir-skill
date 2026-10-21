defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer order report from rows produced by a CSV parser.

  Each row is a map with string keys and string values:

      %{
        "customer_id" => "c-42",
        "amount" => "19.99",
        "currency" => "EUR",
        "placed_at" => "2024-05-01T10:15:00Z",
        "status" => "completed"
      }

  Amounts are kept as `Decimal`s so totals are exact. `placed_at` must carry
  a UTC offset (`Z` or `+02:00`); it is normalised to UTC, so the reported
  date of a customer's most recent order is a UTC date.
  """

  @top_customers_count 5

  @type row :: %{optional(String.t()) => String.t()}

  @type customer_report :: %{
          totals: %{(currency :: String.t()) => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{(customer_id :: String.t()) => customer_report()},
          top_customers: [{customer_id :: String.t(), completed_orders :: pos_integer()}]
        }

  @type error ::
          {:invalid_order, index :: non_neg_integer(),
           :missing_fields
           | {:invalid_amount, String.t()}
           | {:invalid_placed_at, String.t(), atom()}
           | {:invalid_status, String.t()}}

  @doc """
  Builds the report.

  For every customer it returns the total spent per currency over completed
  orders, and the date of their most recent order of any status. Customers
  with no completed orders appear with empty totals.

  `top_customers` lists up to #{@top_customers_count} customers with the most
  completed orders, highest first. Ties are broken by customer id so the
  result is stable.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, where `index` is its zero-based position in `rows`.
  """
  @spec build([row()]) :: {:ok, report()} | {:error, error()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, %{customers: customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, orders} ->
      {customer_id, %{totals: totals_by_currency(orders), last_order_on: last_order_on(orders)}}
    end)
  end

  defp totals_by_currency(orders) do
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
    |> Enum.take(@top_customers_count)
  end

  # Parsing. Aggregation does not depend on row order, so the accumulated
  # list is left reversed.

  defp parse_rows(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse_row(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
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

  defp parse_row(_row), do: {:error, :missing_fields}

  defp parse_amount(amount) do
    case Decimal.parse(amount) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, {:invalid_amount, amount}}
    end
  end

  defp parse_placed_at(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_placed_at, placed_at, reason}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(status), do: {:error, {:invalid_status, status}}
end
