defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with an offset), and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
  """

  @top_size 5

  @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
  defstruct @enforce_keys

  @type status :: :completed | :refunded | :pending

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: status()
        }

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  `totals` in each customer summary sums completed orders only, keyed by
  currency. `last_order_on` is the UTC date of the customer's latest order of
  any status. `top_customers` lists up to five `{customer_id, count}` pairs,
  most completed orders first, with ties broken by customer id.

  Returns `{:error, {:invalid_row, row}}`, `{:error, {:invalid_amount, value}}`,
  `{:error, {:invalid_placed_at, value}}`, or `{:error, {:unknown_status, value}}`
  for the first row that fails to parse.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_order(%{
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
       %__MODULE__{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse_order(row), do: {:error, {:invalid_row, row}}

  defp parse_amount(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: coef} = amount, ""} when is_integer(coef) -> {:ok, amount}
      _ -> {:error, {:invalid_amount, value}}
    end
  end

  defp parse_placed_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_placed_at, value}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{
      totals: totals_by_currency(orders),
      last_order_on: orders |> Enum.map(&DateTime.to_date(&1.placed_at)) |> Enum.max(Date)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_size)
  end

  defp completed?(%__MODULE__{status: status}), do: status == :completed
end
