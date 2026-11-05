defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from orders parsed out of CSV rows.

  Each row is a map with string keys:

    * `"customer_id"` - the customer's id
    * `"amount"` - a decimal string such as `"19.99"`
    * `"currency"` - a currency code such as `"EUR"`
    * `"placed_at"` - an ISO 8601 datetime such as `"2026-03-01T10:15:00Z"`
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`
  """

  @top_count 5

  @typedoc "One customer's summary: spend per currency, completed orders, last order."
  @type customer :: %{
          spent: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_placed_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of CSV rows.

  Returns `{:ok, report}`, or `{:error, reason}` when a row is malformed.

  `:spent` and `:completed_count` count only orders with status `"completed"`.
  `:last_placed_at` is the latest `placed_at` across all of a customer's
  orders, whatever their status.

  `:top_customers` lists up to five `{customer_id, completed_count}` pairs,
  most completed orders first, with ties ordered by customer id. Customers
  with no completed orders are left out.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = summarize_customers(orders)

      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rows], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rows, [order | orders])
    end
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "currency" => currency,
         "amount" => amount_text,
         "placed_at" => placed_at_text,
         "status" => status_text
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status} <- parse_status(status_text) do
      order = %{
        customer_id: customer_id,
        currency: currency,
        amount: amount,
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
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      spent: spent_by_currency(completed),
      completed_count: Enum.count(completed),
      last_placed_at: latest_placed_at(orders)
    }
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp latest_placed_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, customer} -> {customer_id, customer.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
