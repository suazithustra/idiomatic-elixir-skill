defmodule Reports.Orders do
  @moduledoc """
  Builds per-customer totals and a top-customers ranking from order rows
  produced by a CSV parser.

  Each row is a string-keyed map with `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  @top_count 5

  @doc """
  Builds the report for a list of order rows.

  The result has two keys:

    * `:customers` - a map from `customer_id` to a summary with `:spent`, the
      sum of completed order amounts per currency, and `:last_order_on`, the
      date (UTC) of the customer's most recent order of any status.
    * `:top_customers` - up to five `{customer_id, count}` pairs, ordered by
      the number of completed orders, highest first. Ties are broken by
      `customer_id`.

    Returns `{:error, reason}` for the first row with a malformed amount,
    date or field set.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}
  """
  @spec build([map()]) :: {:ok, map()} | {:error, term()}
  def build(orders) do
    with {:ok, rows} <- parse_orders(orders) do
      {:ok, summarize(rows)}
    end
  end

  defp summarize(rows) do
    completed = Enum.filter(rows, &(&1.status == "completed"))

    %{customers: customers(rows), top_customers: top_customers(completed)}
  end

  defp customers(rows) do
    rows
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, rows} -> {customer_id, customer_summary(rows)} end)
  end

  defp customer_summary(rows) do
    completed = Enum.filter(rows, &(&1.status == "completed"))

    %{
      spent: spent_by_currency(completed),
      last_order_on: Enum.max(Enum.map(rows, & &1.placed_on), Date)
    }
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, total(amounts)} end)
  end

  defp total(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp top_customers(completed) do
    completed
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp parse_orders([]), do: {:ok, []}

  defp parse_orders([order | rest]) do
    with {:ok, row} <- parse_order(order),
         {:ok, rows} <- parse_orders(rest) do
      {:ok, [row | rows]}
    end
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => text,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(text),
         {:ok, placed_on} <- parse_date(placed_at) do
      row = %{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_on: placed_on,
        status: status
      }

      {:ok, row}
    end
  end

  defp parse_order(_order), do: {:error, :invalid_order}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_amount, text}}
      :error -> {:error, {:invalid_amount, text}}
    end
  end

  defp parse_date(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, _reason} -> {:error, {:invalid_placed_at, text}}
    end
  end
end
