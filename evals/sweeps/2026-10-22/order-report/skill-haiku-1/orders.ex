defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from orders parsed from CSV.

  Each order is a string-keyed map with `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).

  The report has two parts:

    * `:customers` maps each customer ID to:
      * `:totals`, a map of currency to `Decimal` total across completed orders
      * `:last_order_at`, the latest `DateTime` across all of the customer's
        orders, whatever their status
    * `:top_customers` lists up to five `%{customer_id: id, completed_orders: n}`
      maps, most completed orders first. Ties are broken by `customer_id`.
  """

  @top_count 5

  @doc """
  Builds the report from parsed CSV rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that fails
  to parse, such as `{:error, {:invalid_field, "amount"}}`.
  """
  @spec build([map()]) :: {:ok, map()} | {:error, term()}
  def build(orders) when is_list(orders) do
    case parse_orders(orders) do
      {:ok, parsed} -> {:ok, summarize(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(orders) do
    Enum.reduce_while(orders, {:ok, []}, &accumulate_order/2)
  end

  defp accumulate_order(order, {:ok, parsed}) do
    case parse_order(order) do
      {:ok, parsed_order} -> {:cont, {:ok, [parsed_order | parsed]}}
      {:error, _reason} = error -> {:halt, error}
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
         {:ok, placed_at} <- parse_time(placed_at),
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

  defp parse_order(order), do: {:error, {:invalid_order, order}}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_time(text) do
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
    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, customer_summary(customer_orders)}
    end)
  end

  defp customer_summary(orders) do
    %{totals: currency_totals(completed(orders)), last_order_at: last_order_at(orders)}
  end

  defp currency_totals(orders) do
    Enum.reduce(orders, %{}, fn order, totals ->
      Map.update(totals, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end)
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
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
