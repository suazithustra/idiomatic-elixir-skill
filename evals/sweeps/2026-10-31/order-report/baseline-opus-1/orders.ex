defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Rules the report follows:

    * Totals count completed orders only. Amounts stay in their own currency
      and are never converted.
    * The most recent order considers every status, so a customer whose only
      order is pending still appears, with empty totals.
    * `placed_at` values are compared as instants, so differing UTC offsets
      order correctly. The reported date is the UTC date. A value with no
      offset is treated as UTC.
    * Top customers are ranked by completed order count. Ties are broken by
      `customer_id` so the result is stable, and customers with no completed
      orders are left out.

  One invalid row fails the whole report, because a report that silently
  skipped rows would understate totals.
  """

  @statuses ~w(completed refunded pending)
  @top_customers_limit 5

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          totals: %{currency() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type top_customer :: %{
          customer_id: customer_id(),
          completed_orders: pos_integer()
        }

  @type report :: %{
          customers: %{customer_id() => customer_summary()},
          top_customers: [top_customer()]
        }

  @type invalid_order :: {:invalid_order, index :: non_neg_integer(), reason :: term()}

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, or `{:error, {:invalid_order, index, reason}}` for
  the first invalid row, where `index` is its zero-based position in `rows`.

  ## Examples

      iex> {:ok, report} =
      ...>   Reports.Orders.build([
      ...>     %{
      ...>       "customer_id" => "c1",
      ...>       "amount" => "19.99",
      ...>       "currency" => "EUR",
      ...>       "placed_at" => "2024-03-01T10:00:00Z",
      ...>       "status" => "completed"
      ...>     }
      ...>   ])
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-01]
      iex> report.top_customers
      [%{customer_id: "c1", completed_orders: 1}]

  """
  @spec build([map()]) :: {:ok, report()} | {:error, invalid_order()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, %{customers: customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(orders) do
    %{
      totals: orders |> Enum.filter(&completed?/1) |> total_by_currency(),
      last_order_on: last_order_on(orders)
    }
  end

  defp total_by_currency(orders) do
    Enum.reduce(orders, %{}, fn order, totals ->
      Map.update(totals, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers_limit)
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end

  defp completed?(order), do: order.status == "completed"

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
       })
       when is_binary(customer_id) and customer_id != "" and is_binary(amount) and
              is_binary(placed_at) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, currency} <- parse_currency(currency),
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

  defp parse_row(_row), do: {:error, :missing_or_blank_field}

  defp parse_amount(amount) do
    with {decimal, ""} <- Decimal.parse(amount),
         false <- Decimal.nan?(decimal) or Decimal.inf?(decimal) do
      {:ok, decimal}
    else
      _ -> {:error, {:invalid_amount, amount}}
    end
  end

  defp parse_currency(<<a, b, c>> = currency)
       when a in ?A..?Z and b in ?A..?Z and c in ?A..?Z do
    {:ok, currency}
  end

  defp parse_currency(currency), do: {:error, {:invalid_currency, currency}}

  defp parse_placed_at(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, :missing_offset} -> parse_naive_as_utc(placed_at)
      {:error, reason} -> {:error, {:invalid_placed_at, placed_at, reason}}
    end
  end

  defp parse_naive_as_utc(placed_at) do
    case NaiveDateTime.from_iso8601(placed_at) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, reason} -> {:error, {:invalid_placed_at, placed_at, reason}}
    end
  end

  defp parse_status(status) when status in @statuses, do: {:ok, status}
  defp parse_status(status), do: {:error, {:invalid_status, status}}
end
