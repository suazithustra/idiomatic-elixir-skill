defmodule Reports.Orders do
  @moduledoc """
  Summarizes order rows from the CSV parser into per-customer totals and a
  ranking of the most frequent customers.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime), and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
  """

  defmodule Order do
    @moduledoc false

    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            customer_id: String.t(),
            amount: Decimal.t(),
            currency: String.t(),
            placed_at: DateTime.t(),
            status: :completed | :refunded | :pending
          }
  end

  @top_count 5

  @doc """
  Builds the report from parsed CSV rows.

  Returns `{:ok, report}` where `report` has:

    * `:customers` - one entry per customer, sorted by `:customer_id`. Each
      entry has `:totals`, the completed spend per currency as a `Decimal`,
      and `:last_order_on`, the `Date` of the customer's latest order. The
      latest order counts whatever its status.
    * `:top_customers` - up to five `{customer_id, count}` pairs, where
      `count` is the number of completed orders. Ties are ordered by
      `customer_id`.

  Returns `{:error, reason}` at the first row with a missing or malformed
  field.
  """
  @spec build([map()]) :: {:ok, map()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, report(orders)}
    end
  end

  defp parse_rows(rows), do: parse_rows(rows, [])

  defp parse_rows([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_rows([row | rest], orders) do
    with {:ok, order} <- parse_row(row) do
      parse_rows(rest, [order | orders])
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
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp report(orders) do
    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Enum.map(fn {customer_id, customer_orders} ->
      customer_summary(customer_id, customer_orders)
    end)
    |> Enum.sort_by(& &1.customer_id)
  end

  defp customer_summary(customer_id, orders) do
    %{
      customer_id: customer_id,
      totals: totals_by_currency(orders),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
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
    |> Enum.sort_by(fn {customer_id, count} ->
      {-count, customer_id}
    end)
    |> Enum.take(@top_count)
  end
end
