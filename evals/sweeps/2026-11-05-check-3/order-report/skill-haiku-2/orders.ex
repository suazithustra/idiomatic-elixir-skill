defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_size 5

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  @doc """
  Builds the report from parsed CSV rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that does
  not parse. The report is a map with two keys:

    * `:customers` - maps each `customer_id` to `%{totals: totals,
      last_order_on: date}`. `totals` maps each currency to the sum of the
      customer's completed orders in that currency, as a `Decimal`.
      `last_order_on` is the UTC date of the customer's most recent order,
      whatever its status.
    * `:top_customers` - up to five `{customer_id, count}` tuples, where
      `count` is the number of completed orders. Highest counts come first;
      ties are ordered by `customer_id`.
  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp summarize(orders) do
    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, customer_summary(customer_orders)}
    end)
  end

  defp customer_summary(customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == :completed))

    %{
      totals: totals_by_currency(completed),
      last_order_on: last_order_on(customer_orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
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
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_size)
  end

  defp parse_rows(rows), do: parse_rows(rows, [])

  defp parse_rows([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_rows([row | rows], orders) do
    with {:ok, order} <- parse_row(row) do
      parse_rows(rows, [order | orders])
    end
  end

  defp parse_row(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      order = %Order{
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
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
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
