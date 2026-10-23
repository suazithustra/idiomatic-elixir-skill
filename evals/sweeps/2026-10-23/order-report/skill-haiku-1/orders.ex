defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from orders parsed from CSV.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (a decimal
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

  @doc """
  Builds the report for a list of raw orders.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that cannot
  be parsed. The report is a map with two keys:

    * `:customers` - a map from `customer_id` to a summary with `:totals`
      (completed spend per currency, as `Decimal` values), `:completed_count`,
      and `:last_order_on` (a `Date` for the latest order of any status).
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first. Customers with no completed orders are left out.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "10.00", "currency" => "EUR",
      ...>     "placed_at" => "2026-01-02T10:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.top_customers
      [{"c1", 1}]

  """
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    results = Enum.map(rows, &parse_order/1)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil -> {:ok, for({:ok, order} <- results, do: order)}
      error -> error
    end
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

  defp parse_order(_row), do: {:error, :invalid_order}

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
  defp parse_status(_status), do: {:error, {:invalid_field, "status"}}

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
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      totals: totals_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(completed_orders) do
    completed_orders
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

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_count > 0 end)
    # Ties go to the lower customer_id, so the same input always gives the same order.
    |> Enum.sort_by(fn {customer_id, summary} ->
      {-summary.completed_count, customer_id}
    end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
  end
end
