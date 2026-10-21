defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from parsed order rows.

  Each row is a map with string keys:

    * `"customer_id"` - a string
    * `"amount"` - a decimal string with at most two decimal places, such as `"19.99"`
    * `"currency"` - a currency code such as `"EUR"`
    * `"placed_at"` - an ISO 8601 datetime, with or without a UTC offset
    * `"status"` - `"completed"`, `"refunded"`, or `"pending"`

  Amounts are converted to integer cents when the row is parsed, so totals are exact.
  Spending totals and the top-customers ranking count only completed orders.
  The most recent order date counts every order, whatever its status.
  Dates are taken in UTC.
  """

  @top_count 5

  @doc """
  Builds the report from order rows.

  Returns `{:ok, report}`, where `report` is a map with:

    * `:customers` - a map from `customer_id` to `%{spent: cents_by_currency, last_order_on: date}`
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples, most completed orders first

  Returns `{:error, reason}` for the first row that does not parse. `reason` is
  `{:missing_field, key}` or `{:invalid_field, key}`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "10.5", "currency" => "EUR", "placed_at" => "2024-03-01T09:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "2", "currency" => "EUR", "placed_at" => "2024-03-05T09:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %{spent: %{"EUR" => 1050}, last_order_on: ~D[2024-03-05]}
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, map()} | {:error, term()}
  def build(rows) do
    case parse_rows(rows, []) do
      {:ok, orders} ->
        {:ok, %{customers: summarize(orders), top_customers: top_customers(orders)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_rows([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_rows([row | rest], orders) do
    case parse_order(row) do
      {:ok, order} -> parse_rows(rest, [order | orders])
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, cents} <- parse_cents(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_on} <- parse_placed_on(row),
         {:ok, status} <- parse_status(row) do
      {:ok,
       %{
         customer_id: customer_id,
         cents: cents,
         currency: currency,
         placed_on: placed_on,
         status: status
       }}
    end
  end

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_cents(row) do
    case string_field(row, "amount") do
      {:ok, text} -> amount_to_cents(text)
      {:error, _reason} = error -> error
    end
  end

  defp amount_to_cents(text) do
    case Regex.run(~r/\A(\d+)(?:\.(\d{1,2}))?\z/, text, capture: :all_but_first) do
      [whole] -> {:ok, String.to_integer(whole) * 100}
      [whole, fraction] -> {:ok, String.to_integer(whole) * 100 + fraction_cents(fraction)}
      nil -> {:error, {:invalid_field, "amount"}}
    end
  end

  # "5" means 50 cents, so the fraction is padded to two digits before reading it
  defp fraction_cents(fraction) do
    String.to_integer(String.pad_trailing(fraction, 2, "0"))
  end

  defp parse_placed_on(row) do
    case string_field(row, "placed_at") do
      {:ok, text} -> placed_on(text)
      {:error, _reason} = error -> error
    end
  end

  defp placed_on(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, :missing_offset} -> naive_placed_on(text)
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp naive_placed_on(text) do
    case NaiveDateTime.from_iso8601(text) do
      {:ok, datetime} -> {:ok, NaiveDateTime.to_date(datetime)}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status(row) do
    case string_field(row, "status") do
      {:ok, "completed"} -> {:ok, :completed}
      {:ok, "refunded"} -> {:ok, :refunded}
      {:ok, "pending"} -> {:ok, :pending}
      {:ok, _other} -> {:error, {:invalid_field, "status"}}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id,
       %{
         spent: spent_by_currency(customer_orders),
         last_order_on: last_order_on(customer_orders)
       }}
    end)
  end

  defp spent_by_currency(orders) do
    orders
    |> completed()
    |> Enum.group_by(& &1.currency, & &1.cents)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.sum(amounts)} end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_on)
    |> Enum.max(Date)
  end

  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    # Negating the count sorts ties by customer_id in ascending order
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
