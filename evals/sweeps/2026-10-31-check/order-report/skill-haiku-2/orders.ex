defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from order rows
  produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_n 5

  @typedoc "Summary of one customer's orders."
  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_orders: non_neg_integer(),
          last_order_on: Date.t()
        }

  @typedoc "The report returned by `build/1`."
  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [%{customer_id: String.t(), completed_orders: pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  `totals` sums completed orders per currency. `last_order_on` is the date of
  the customer's most recent order of any status, in UTC. `top_customers` lists
  up to five customers with the most completed orders, most first; ties are
  ordered by `customer_id`.

  Returns `{:error, reason}` for a row with a missing or malformed field.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
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
        {customer_id, customer_summary(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp customer_summary(orders) do
    %{
      totals: totals_by_currency(orders),
      completed_orders: Enum.count(orders, &completed?/1),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      total =
        Enum.reduce(currency_orders, Decimal.new(0), fn order, total ->
          Decimal.add(total, order.amount)
        end)

      {currency, total}
    end)
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} ->
      %{customer_id: customer_id, completed_orders: summary.completed_orders}
    end)
    |> Enum.filter(&(&1.completed_orders > 0))
    |> Enum.sort_by(fn row -> {-row.completed_orders, row.customer_id} end)
    |> Enum.take(@top_n)
  end

  defp completed?(order), do: order.status == :completed

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
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
