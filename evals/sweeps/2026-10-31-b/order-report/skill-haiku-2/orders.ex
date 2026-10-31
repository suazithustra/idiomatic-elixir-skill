defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from order rows parsed from CSV.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with a UTC offset) and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  The report has two parts:

    * `customers`: for each customer, the total of completed orders per
      currency, and the UTC date of the most recent order of any status.
    * `top_customers`: up to five customers with the most completed orders.
      Ties are broken by ascending `customer_id`.

  Refunded and pending orders do not count toward totals or rankings.
  """

  @top_size 5

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  @doc """
  Builds the report, or returns the first row that cannot be parsed.

  Errors are `:invalid_order` (a required key is missing),
  `{:invalid_field, name}` (an amount or datetime does not parse) and
  `{:unknown_status, value}`.

  ## Examples

      iex> {:ok, report} =
      ...>   Reports.Orders.build([
      ...>     %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>       "placed_at" => "2024-01-10T10:00:00Z", "status" => "completed"}
      ...>   ])
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("19.99")}
  """
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows, []) do
      {:ok, report(orders)}
    end
  end

  defp report(orders) do
    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders)
    }
  end

  defp parse_orders([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_orders([row | rest], acc) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rest, [order | acc])
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

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(customer_orders) do
    %{
      totals: spent_by_currency(customer_orders),
      last_order_on: last_order_on(customer_orders)
    }
  end

  defp spent_by_currency(customer_orders) do
    customer_orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum_decimals(amounts)} end)
  end

  defp last_order_on(customer_orders) do
    customer_orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    ranking =
      orders
      |> Enum.filter(&completed?/1)
      |> Enum.frequencies_by(& &1.customer_id)
      |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
      |> Enum.take(@top_size)

    for {customer_id, count} <- ranking do
      %{customer_id: customer_id, completed_orders: count}
    end
  end

  defp completed?(order), do: order.status == :completed

  defp sum_decimals(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)
end
