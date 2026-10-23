defmodule Reports.Orders do
  @moduledoc """
  Builds a report from orders produced by the CSV parser.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string, such as `"19.99"`
    * `"currency"` - such as `"EUR"` or `"USD"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are kept as integers in minor units (cents), so no float rounding happens.

  The report has this shape:

      %{
        customers: %{
          "c1" => %{spent: %{"EUR" => 1999}, last_order_date: ~D[2024-03-01]}
        },
        top_customers: [{"c1", 3}]
      }

    * `spent` sums only completed orders, per currency.
    * `last_order_date` is the latest `placed_at` date across all of the
      customer's orders, whatever their status.
    * `top_customers` lists up to 5 `{customer_id, completed_count}` tuples,
      highest count first. Ties are broken by `customer_id`.
  """

  @top_n 5
  @amount_pattern ~r/\A(-?)(\d+)(?:\.(\d{1,2}))?\z/

  @type cents :: integer()

  @type customer_summary :: %{
          spent: %{String.t() => cents()},
          last_order_date: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order maps.

  Raises `ArgumentError` on a malformed amount and `MatchError` on a malformed
  `placed_at`.
  """
  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    customers =
      orders
      |> Enum.group_by(& &1["customer_id"])
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize(orders) do
    spent =
      orders
      |> Enum.filter(&completed?/1)
      |> Enum.group_by(& &1["currency"], &parse_cents(&1["amount"]))
      |> Map.new(fn {currency, amounts} -> {currency, Enum.sum(amounts)} end)

    last_order_date =
      orders
      |> Enum.map(&placed_date/1)
      |> Enum.max(Date)

    %{spent: spent, last_order_date: last_order_date}
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1["customer_id"])
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
  end

  defp completed?(order), do: order["status"] == "completed"

  defp placed_date(order) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(order["placed_at"])
    DateTime.to_date(datetime)
  end

  defp parse_cents(amount) do
    case Regex.run(@amount_pattern, amount) do
      [_, sign, whole | fraction] ->
        cents = String.to_integer(whole) * 100 + fraction_cents(fraction)
        if sign == "-", do: -cents, else: cents

      nil ->
        raise ArgumentError, "invalid amount: #{inspect(amount)}"
    end
  end

  defp fraction_cents([]), do: 0
  defp fraction_cents([fraction]), do: fraction |> String.pad_trailing(2, "0") |> String.to_integer()
end
