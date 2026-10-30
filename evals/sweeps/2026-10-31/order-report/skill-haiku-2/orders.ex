defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime), and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Only completed orders count toward spending and the top customers. The date
  of a customer's most recent order is taken over all of their orders,
  whatever their status.

  The report is a map with two keys:

    * `:customers` - maps each customer ID to `%{totals: ..., last_order_at: ...}`.
      `totals` maps each currency to the sum of the customer's completed orders
      in that currency, as a `Decimal`.
    * `:top_customers` - up to five `{customer_id, count}` tuples, most completed
      orders first. Ties are ordered by customer ID.
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

  @typedoc "Per-customer figures: currency totals and the latest order date."
  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_count 5

  @doc """
  Builds the report from order rows.

  Returns `{:error, {:invalid_field, field}}` for the first row whose field is
  missing or malformed.

  ## Examples

      iex> row = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "10.00",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2026-01-02T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> {:ok, report} = Reports.Orders.build([row])
      iex> report.top_customers
      [{"c1", 1}]

  """
  @spec build([map()]) :: {:ok, report()} | {:error, {:invalid_field, String.t()}}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows, []) do
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
    %{
      totals: customer_orders |> completed() |> totals_by_currency(),
      last_order_at: last_order_at(customer_orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rows], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rows, [order | orders])
    end
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

  defp string_field(row, field) do
    case Map.fetch(row, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, field}}
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
  defp parse_status(_unknown), do: {:error, {:invalid_field, "status"}}
end
