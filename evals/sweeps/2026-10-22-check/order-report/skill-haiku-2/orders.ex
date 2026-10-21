defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
  """

  @top_size 5

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_on, :status]
    defstruct @enforce_keys
  end

  @doc """
  Builds the report from a list of parsed CSV rows.

  Returns `{:ok, report}` or `{:error, reason}` for the first row that does
  not parse. The report is a map with two keys:

    * `:customers` - one summary per customer, each a map with
      `:customer_id`, `:totals` (completed spend per currency as `Decimal`
      values, keyed by currency code), `:last_order_on` (the latest `Date`
      across all of the customer's orders, whatever their status), and
      `:completed_count`.
    * `:top_customers` - up to five of the summaries above, ordered by
      `:completed_count` descending. Ties are broken by `:customer_id`.
  """
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Enum.map(&summarize_customer/1)

    top_customers =
      customers
      |> Enum.sort_by(&{-&1.completed_count, &1.customer_id})
      |> Enum.take(@top_size)

    %{customers: customers, top_customers: top_customers}
  end

  defp summarize_customer({customer_id, orders}) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customer_id: customer_id,
      totals: totals_by_currency(completed),
      last_order_on: orders |> Enum.map(& &1.placed_on) |> Enum.max(Date),
      completed_count: length(completed)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} -> {currency, sum_amounts(orders)} end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp parse_orders(rows) do
    result =
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        case parse_order(row) do
          {:ok, order} -> {:cont, {:ok, [order | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- fetch_field(row, "customer_id"),
         {:ok, amount_text} <- fetch_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- fetch_field(row, "currency"),
         {:ok, placed_text} <- fetch_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_text),
         {:ok, status_text} <- fetch_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      {:ok,
       %Order{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_on: DateTime.to_date(placed_at),
         status: status
       }}
    end
  end

  defp fetch_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      _invalid -> {:error, {:invalid_field, "amount"}}
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
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
