defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report and a top-customers ranking from parsed CSV order rows.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with an offset) and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Spending totals and the top-customers ranking count only completed orders.
  The last order time covers every order, whatever its status.
  """

  @top_count 5

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

  @typedoc "Spending per currency and the time of the customer's latest order."
  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_placed_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from order rows.

  Returns `{:ok, report}`, where `report` is a map with:

    * `:customers` - each customer id mapped to `%{totals: ..., last_placed_at: ...}`.
      `totals` maps each currency to the sum of the customer's completed orders in
      that currency. `last_placed_at` is the time of their latest order of any status.
    * `:top_customers` - up to five `{customer_id, count}` tuples, where `count` is
      the number of completed orders. Ties are ordered by customer id.

  Returns `{:error, reason}` for the first row that does not parse.

  ## Examples

      iex> row = %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR", "placed_at" => "2026-01-05T10:00:00Z", "status" => "completed"}
      iex> {:ok, report} = Reports.Orders.build([row])
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_rows(rows) do
    case Enum.reduce_while(rows, {:ok, []}, &parse_into/2) do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_into(row, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_text),
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

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(&summarize_customer/1)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer({customer_id, orders}) do
    {customer_id, %{totals: totals(orders), last_placed_at: last_placed_at(orders)}}
  end

  defp totals(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(&sum_currency/1)
  end

  defp sum_currency({currency, amounts}) do
    {currency, Enum.reduce(amounts, &Decimal.add/2)}
  end

  defp last_placed_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(order), do: order.status == :completed
end
