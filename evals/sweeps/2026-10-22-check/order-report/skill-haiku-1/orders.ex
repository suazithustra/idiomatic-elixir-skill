defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
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

  @typedoc "Summary of one customer's orders."
  @type customer :: %{
          customer_id: String.t(),
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t(),
          completed_count: non_neg_integer()
        }

  @type report :: %{customers: [customer()], top_customers: [customer()]}

  @doc """
  Builds the report from parsed order rows.

  Each customer's `:totals` sums their completed orders per currency. Their
  `:last_order_on` is the UTC date of their latest order, whatever its status.
  `:top_customers` holds up to five customers with the most completed orders,
  highest first.

  Returns `{:error, reason}` for the first row that cannot be parsed.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_rows(rows) do
    results = Enum.map(rows, &parse_row/1)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, for({:ok, order} <- results, do: order)}
      error -> error
    end
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
       %Order{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse_row(row), do: {:error, {:invalid_row, row}}

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
      |> Enum.map(&summarize_customer/1)
      |> Enum.sort_by(& &1.customer_id)

    %{
      customers: customers,
      top_customers: top_customers(customers)
    }
  end

  defp summarize_customer({customer_id, orders}) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customer_id: customer_id,
      totals: totals_by_currency(completed),
      last_order_on: last_order_on(orders),
      completed_count: Enum.count(completed)
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

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(customers) do
    customers
    |> Enum.sort_by(& &1.completed_count, :desc)
    |> Enum.take(@top_count)
  end
end
