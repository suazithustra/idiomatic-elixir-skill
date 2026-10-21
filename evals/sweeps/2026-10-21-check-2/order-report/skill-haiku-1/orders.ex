defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from CSV order rows.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).

  Spending totals and the ranking count completed orders only. The last order
  date covers every status, because a refunded or pending order is still an
  order the customer placed.
  """

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  @top_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns a map with:

    * `:customers` - a map from `customer_id` to a map with `:totals`
      (currency to `Decimal` total of completed orders), `:completed_count`,
      and `:last_order_at` (a `DateTime`)
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first

  Raises on a malformed row. The rows come from a parser that has already
  checked the file, so a bad row is a bug to surface, not a row to skip.

  ## Examples

      iex> Reports.Orders.build([])
      %{customers: %{}, top_customers: []}
  """
  def build(rows) do
    orders = Enum.map(rows, &parse_row/1)

    %{
      customers: summarize_customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp parse_row(row) do
    %{
      "customer_id" => customer_id,
      "amount" => amount,
      "currency" => currency,
      "placed_at" => placed_at,
      "status" => status
    } = row

    {decimal_amount, ""} = Decimal.parse(amount)
    {:ok, placed_at, _offset} = DateTime.from_iso8601(placed_at)

    %Order{
      customer_id: customer_id,
      amount: decimal_amount,
      currency: currency,
      placed_at: placed_at,
      status: parse_status(status)
    }
  end

  defp parse_status("completed"), do: :completed
  defp parse_status("refunded"), do: :refunded
  defp parse_status("pending"), do: :pending

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == :completed))

    %{
      totals: totals_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_at: customer_orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    # Ties are ordered by customer_id so the ranking is the same on every run.
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
