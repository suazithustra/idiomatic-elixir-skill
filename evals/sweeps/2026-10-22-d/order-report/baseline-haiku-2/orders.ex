defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by the CSV parser.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Only completed orders count towards spending and the top-customer ranking.
  The date of the most recent order considers every order, whatever its status.
  """

  @top_count 5

  @doc """
  Builds the report for a list of orders.

  Returns a map with:

    * `:customers` - a map from customer id to
      `%{spent: %{currency => Decimal.t()}, last_order_at: DateTime.t()}`
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first
  """
  def build(orders) do
    orders = Enum.map(orders, &parse/1)

    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp parse(order) do
    %{
      customer_id: Map.fetch!(order, "customer_id"),
      amount: Decimal.new(Map.fetch!(order, "amount")),
      currency: Map.fetch!(order, "currency"),
      placed_at: parse_datetime!(Map.fetch!(order, "placed_at")),
      status: Map.fetch!(order, "status")
    }
  end

  defp parse_datetime!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(value)}: #{reason}"
    end
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &completed?/1)

    %{
      spent: spent_by_currency(completed),
      last_order_at: orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime)
    }
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(%{status: status}), do: status == "completed"
end
