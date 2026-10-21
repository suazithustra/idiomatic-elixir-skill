defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed order rows.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string such as `"19.99"`
    * `"currency"` - such as `"EUR"` or `"USD"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are stored as integer minor units (cents), so `"19.99"` becomes
  `1999`. This avoids floating-point rounding errors and needs no dependency.

  Only completed orders count toward spend and toward the top customers.
  Every order, whatever its status, counts toward a customer's last order date.
  Dates are taken in UTC.
  """

  @top_n 5

  @type customer :: %{
          spent: %{String.t() => integer()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer()},
          top_customers: [%{customer_id: String.t(), completed_orders: pos_integer()}]
        }

  @doc """
  Returns a report with a summary per customer and the top completed-order customers.

  Raises `ArgumentError` for a malformed amount and `MatchError` or
  `ArgumentError` for a malformed `placed_at` value.
  """
  @spec build([map()]) :: report()
  def build(orders) do
    customers =
      orders
      |> Enum.group_by(& &1["customer_id"])
      |> Map.new(fn {customer_id, rows} -> {customer_id, summarize_customer(rows)} end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(rows) do
    spent =
      rows
      |> Enum.filter(&completed?/1)
      |> Enum.reduce(%{}, fn order, acc ->
        cents = parse_amount(order["amount"])
        Map.update(acc, order["currency"], cents, &(&1 + cents))
      end)

    last_order_on =
      rows
      |> Enum.map(&placed_on/1)
      |> Enum.max(Date)

    %{spent: spent, last_order_on: last_order_on}
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1["customer_id"])
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end

  defp completed?(%{"status" => "completed"}), do: true
  defp completed?(_order), do: false

  defp parse_amount("-" <> rest), do: -parse_amount(rest)

  defp parse_amount(amount) do
    case String.split(amount, ".") do
      [whole] ->
        String.to_integer(whole) * 100

      [whole, fraction] when fraction != "" and byte_size(fraction) <= 2 ->
        cents = String.to_integer(String.pad_trailing(fraction, 2, "0"))
        String.to_integer(whole) * 100 + cents

      _ ->
        raise ArgumentError, "invalid amount: #{inspect(amount)}"
    end
  end

  defp placed_on(%{"placed_at" => placed_at}) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} ->
        DateTime.to_date(datetime)

      {:error, :missing_offset} ->
        placed_at
        |> NaiveDateTime.from_iso8601!()
        |> NaiveDateTime.to_date()
    end
  end
end
