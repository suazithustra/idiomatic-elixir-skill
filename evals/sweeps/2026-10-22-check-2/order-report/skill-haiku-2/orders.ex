defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Spend totals and the top-customer ranking count only `"completed"` orders.
  `last_order_at` is the placement time of the customer's most recent order,
  whatever its status.
  """

  @top_count 5

  @doc """
  Builds the report from a list of string-keyed order maps.

  Returns `{:ok, report}`, where `report` has:

    * `:customers` - a map from `customer_id` to
      `%{spent: %{currency => Decimal}, last_order_at: DateTime}`
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first

  Returns `{:error, reason}` for the first row with a missing or invalid field.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}
  """
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
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

  defp parse_order(row) do
    with {:ok, customer_id} <- field(row, "customer_id"),
         {:ok, amount_text} <- field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- field(row, "currency"),
         {:ok, placed_text} <- field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_text),
         {:ok, status_text} <- field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
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

  defp field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} -> {:ok, value}
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
    orders_by_customer = Enum.group_by(orders, & &1.customer_id)
    customers = Map.new(orders_by_customer, &customer_entry/1)

    %{customers: customers, top_customers: top_customers(orders_by_customer)}
  end

  defp customer_entry({customer_id, orders}) do
    {customer_id, customer_summary(orders)}
  end

  defp customer_summary(orders) do
    %{spent: spent_by_currency(orders), last_order_at: last_order_at(orders)}
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(orders_by_customer) do
    orders_by_customer
    |> Enum.map(fn {customer_id, orders} ->
      {customer_id, Enum.count(orders, &completed?/1)}
    end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(order), do: order.status == :completed
end
