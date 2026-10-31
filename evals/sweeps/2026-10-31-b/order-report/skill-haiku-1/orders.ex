defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Only completed orders count toward spend and the top-customer ranking. The
  last order date counts every order, whatever its status.
  """

  @top_count 5

  @typedoc "Totals for one customer."
  @type customer :: %{
          customer_id: String.t(),
          spent: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{customers: [customer()], top_customers: [customer()]}

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that cannot
  be parsed. `report.customers` holds every customer, sorted by `customer_id`.
  `report.top_customers` holds up to five customers with at least one completed
  order, most completed orders first, ties broken by `customer_id`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "10.00", "currency" => "EUR",
      ...>     "placed_at" => "2026-01-05T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "2.50", "currency" => "EUR",
      ...>     "placed_at" => "2026-02-01T09:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, %{customers: [customer]}} = Reports.Orders.build(rows)
      iex> customer.completed_count
      1
      iex> customer.last_order_on
      ~D[2026-02-01]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      customers = summarize(orders)

      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_rows(rows) do
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
         {:ok, placed_at} <- parse_datetime(placed_at),
         {:ok, status} <- parse_status(status) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse_order(_row), do: {:error, :invalid_row}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_amount, text}}
      :error -> {:error, {:invalid_amount, text}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_placed_at, text}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Enum.map(fn {customer_id, group} -> summarize_customer(customer_id, group) end)
    |> Enum.sort_by(& &1.customer_id)
  end

  defp summarize_customer(customer_id, orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customer_id: customer_id,
      spent: spent_by_currency(completed),
      completed_count: length(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(&(&1.completed_count > 0))
    |> Enum.sort_by(&{-&1.completed_count, &1.customer_id})
    |> Enum.take(@top_count)
  end
end
