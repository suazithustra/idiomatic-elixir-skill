defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows parsed from CSV.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"` (such as `"EUR"`), `"placed_at"` (an
  ISO 8601 datetime with a UTC offset, such as `"2024-03-01T10:00:00Z"`) and
  `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Spend and the completed-order count use completed orders only. The most
  recent order date uses every order, whatever its status.
  """

  @top_count 5

  @doc """
  Builds the report for a list of order rows.

  Returns `{:ok, report}`, where `report` has these keys:

    * `:customers` - a map from `customer_id` to a map with `:spent`
      (currency to `Decimal` total of completed orders), `:completed_count`
      and `:last_order_on` (a `Date`)
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first. Ties are ordered by `customer_id`.

  Returns `{:error, reason}` for the first row whose amount or `placed_at`
  does not parse.
  """
  @spec build([map()]) :: {:ok, map()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
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
         "amount" => amount_text,
         "currency" => currency,
         "placed_at" => placed_at_text,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_placed_at(placed_at_text) do
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

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_amount, text}}
      :error -> {:error, {:invalid_amount, text}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_placed_at, text}}
    end
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == "completed"))
    latest = Enum.max_by(customer_orders, & &1.placed_at, DateTime)

    %{
      spent: spent_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on: DateTime.to_date(latest.placed_at)
    }
  end

  defp spent_by_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} ->
      {customer_id, summary.completed_count}
    end)
    |> Enum.sort_by(fn {customer_id, count} ->
      {-count, customer_id}
    end)
    |> Enum.take(@top_count)
  end
end
