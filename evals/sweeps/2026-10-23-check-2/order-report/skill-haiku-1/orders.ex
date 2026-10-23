defmodule Reports.Orders do
  @moduledoc """
  Builds per-customer totals and a top-customers ranking from parsed CSV order rows.
  """

  @top_customer_limit 5

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  @doc """
  Builds the report from parsed CSV rows.

  Returns `{:ok, report}`, where `report` is a map with:

    * `:customers` - a map from `customer_id` to a map with `:spent` (currency
      to `Decimal` total over completed orders), `:last_order_at` (the latest
      `DateTime` over orders of any status) and `:completed_orders` (a count)
    * `:top_customers` - up to five maps with `:customer_id` and
      `:completed_orders`, most completed orders first. Customers with no
      completed orders are left out.

  Returns `{:error, reason}` for the first row that cannot be parsed.
  """
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, report(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp report(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      spent: spent_by_currency(completed),
      last_order_at: orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime),
      completed_orders: Enum.count(completed)
    }
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} ->
      %{customer_id: customer_id, completed_orders: summary.completed_orders}
    end)
    |> Enum.reject(&(&1.completed_orders == 0))
    |> Enum.sort_by(& &1.completed_orders, :desc)
    |> Enum.take(@top_customer_limit)
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, &accumulate_row/2)
  end

  defp accumulate_row(row, {:ok, orders}) do
    case parse_row(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp parse_row(%{
         "customer_id" => customer_id,
         "amount" => amount_text,
         "currency" => currency,
         "placed_at" => placed_at_text,
         "status" => status_text
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
         {:ok, status} <- parse_status(status_text) do
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

  defp parse_row(_row), do: {:error, :invalid_row}

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
end
