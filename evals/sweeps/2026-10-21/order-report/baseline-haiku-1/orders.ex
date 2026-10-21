defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by the CSV parser.

  Each row is a map with string keys: "customer_id", "amount" (decimal
  string such as "19.99"), "currency", "placed_at" (ISO 8601 datetime) and
  "status" ("completed", "refunded" or "pending").

  Amounts are summed as integer cents, so totals are exact and do not
  depend on floating point. Amounts with more than two fractional digits
  are rejected.
  """

  @top_n 5

  @type row :: %{required(String.t()) => String.t()}

  @type customer_report :: %{
          spent: %{String.t() => String.t()},
          completed_orders: non_neg_integer(),
          last_order_date: Date.t()
        }

  @doc """
  Builds the report from a list of order rows.

  Returns a map with:

    * `:customers` - a map from customer_id to a `t:customer_report/0`.
      `:spent` only includes completed orders, keyed by currency, with
      amounts as strings such as `"19.99"`. `:last_order_date` is the UTC
      date of the customer's most recent order, whatever its status.

    * `:top_customers` - up to five `{customer_id, completed_orders}` tuples,
      highest count first. Ties are ordered by customer_id. Customers with
      no completed orders are left out.

  Raises `ArgumentError` if a row is missing a field or holds a value that
  cannot be parsed.
  """
  @spec build([row()]) :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), non_neg_integer()}]
        }
  def build(orders) when is_list(orders) do
    customers =
      orders
      |> Enum.map(&parse_row!/1)
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, rows} -> {customer_id, summarize(rows)} end)

    top_customers =
      customers
      |> Enum.map(fn {customer_id, report} -> {customer_id, report.completed_orders} end)
      |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
      |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
      |> Enum.take(@top_n)

    %{customers: customers, top_customers: top_customers}
  end

  defp parse_row!(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    %{
      customer_id: customer_id,
      cents: parse_cents!(amount),
      currency: currency,
      placed_at: parse_datetime!(placed_at),
      status: status
    }
  end

  defp parse_row!(row) do
    raise ArgumentError, "order is missing a required field: #{inspect(row)}"
  end

  defp parse_cents!(amount) do
    case Regex.run(~r/\A(\d+)(?:\.(\d{1,2}))?\z/, String.trim(amount)) do
      [_, whole] ->
        String.to_integer(whole) * 100

      [_, whole, fraction] ->
        String.to_integer(whole) * 100 +
          String.to_integer(String.pad_trailing(fraction, 2, "0"))

      nil ->
        raise ArgumentError, "invalid amount: #{inspect(amount)}"
    end
  end

  defp parse_datetime!(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(placed_at)}: #{reason}"
    end
  end

  # `rows` is never empty, because it comes from group_by/2.
  defp summarize(rows) do
    completed = Enum.filter(rows, &(&1.status == "completed"))

    spent =
      completed
      |> Enum.group_by(& &1.currency, & &1.cents)
      |> Map.new(fn {currency, cents} -> {currency, format_cents(Enum.sum(cents))} end)

    last_order_date =
      rows
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)
      |> DateTime.to_date()

    %{
      spent: spent,
      completed_orders: length(completed),
      last_order_date: last_order_date
    }
  end

  defp format_cents(cents) do
    whole = div(cents, 100)
    fraction = rem(cents, 100)
    "#{whole}.#{String.pad_leading(Integer.to_string(fraction), 2, "0")}"
  end
end
