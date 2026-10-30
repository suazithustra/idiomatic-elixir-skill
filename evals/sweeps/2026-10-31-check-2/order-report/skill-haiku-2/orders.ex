defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime string) and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Spending totals and the completed-order count use completed orders only.
  The last order date uses all orders, whatever their status.
  """

  @top_count 5

  @typedoc "One customer's totals. `spent` is keyed by currency code."
  @type customer_summary :: %{
          customer_id: String.t(),
          spent: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @typedoc "The report returned by `build/1`."
  @type report :: %{
          customers: [customer_summary()],
          top_customers: [customer_summary()]
        }

  @doc """
  Builds the report from parsed CSV rows.

  Returns `{:ok, report}`, or `{:error, reason}` when a row is malformed.
  `customers` is sorted by `customer_id`. `top_customers` holds up to five
  customers, highest completed-order count first. Ties are broken by
  `customer_id`.

  ## Examples

      iex> {:ok, report} = Reports.Orders.build([])
      iex> report
      %{customers: [], top_customers: []}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows) do
    results = Enum.map(rows, &parse_order/1)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil ->
        orders =
          for {:ok, order} <- results do
            order
          end

        {:ok, orders}

      error ->
        error
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
         {:ok, placed_at} <- parse_datetime(placed_at),
         {:ok, status} <- parse_status(status) do
      order = %{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_at: placed_at,
        status: status
      }

      {:ok, order}
    end
  end

  defp parse_order(_row), do: {:error, :invalid_row}

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

  defp summarize(orders) do
    customers = customer_summaries(orders)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Enum.map(fn {customer_id, customer_orders} ->
      summarize_customer(customer_id, customer_orders)
    end)
    |> Enum.sort_by(& &1.customer_id)
  end

  defp summarize_customer(customer_id, customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == :completed))

    latest_placed_at =
      customer_orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{
      customer_id: customer_id,
      spent: spent_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on: DateTime.to_date(latest_placed_at)
    }
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp top_customers(customers) do
    customers
    |> Enum.sort_by(fn customer ->
      {-customer.completed_count, customer.customer_id}
    end)
    |> Enum.take(@top_count)
  end
end
