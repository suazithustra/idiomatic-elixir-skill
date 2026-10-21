defmodule Reports.Orders do
  @moduledoc """
  Builds a summary report from order rows produced by the CSV parser.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string such as `"19.99"`
    * `"currency"` - currency code such as `"EUR"` or `"USD"`
    * `"placed_at"` - ISO 8601 datetime with offset
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are stored as integers in minor units (cents) to avoid floating
  point error. Only completed orders count toward spend and the
  top-customers ranking. The last order date considers all statuses.
  """

  @top_n 5

  @type customer_report :: %{
          spent: %{String.t() => integer()},
          completed_count: non_neg_integer(),
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report from a list of order maps.

  Returns a map with:

    * `:customers` - per customer id: `:spent` (cents per currency),
      `:completed_count` and `:last_order_at`
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples,
      highest count first, ties broken by customer id
  """
  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    customers =
      Enum.reduce(orders, %{}, fn order, acc ->
        add_order(acc, parse_order(order))
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp parse_order(order) do
    %{
      customer_id: Map.fetch!(order, "customer_id"),
      amount: parse_minor_units(Map.fetch!(order, "amount")),
      currency: Map.fetch!(order, "currency"),
      placed_at: parse_datetime!(Map.fetch!(order, "placed_at")),
      status: Map.fetch!(order, "status")
    }
  end

  defp add_order(customers, order) do
    entry =
      Map.get(customers, order.customer_id, %{
        spent: %{},
        completed_count: 0,
        last_order_at: nil
      })

    entry = %{entry | last_order_at: latest(entry.last_order_at, order.placed_at)}

    entry =
      if order.status == "completed" do
        add_completed(entry, order)
      else
        entry
      end

    Map.put(customers, order.customer_id, entry)
  end

  defp add_completed(entry, order) do
    spent = Map.update(entry.spent, order.currency, order.amount, &(&1 + order.amount))
    %{entry | spent: spent, completed_count: entry.completed_count + 1}
  end

  defp latest(nil, placed_at), do: placed_at

  defp latest(current, placed_at) do
    if DateTime.compare(placed_at, current) == :gt, do: placed_at, else: current
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, entry} -> {id, entry.completed_count} end)
    |> Enum.filter(fn {_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end

  # "19.99" -> 1999, "-0.5" -> -50, "7" -> 700
  defp parse_minor_units(amount) when is_binary(amount) do
    {sign, digits} =
      case amount do
        "-" <> rest -> {-1, rest}
        _ -> {1, amount}
      end

    cents =
      case String.split(digits, ".") do
        [whole] ->
          String.to_integer(whole) * 100

        [whole, fraction] when byte_size(fraction) in 1..2 ->
          String.to_integer(whole) * 100 +
            String.to_integer(String.pad_trailing(fraction, 2, "0"))

        _ ->
          raise ArgumentError, "invalid amount: #{inspect(amount)}"
      end

    sign * cents
  end

  defp parse_datetime!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise ArgumentError, "invalid placed_at #{inspect(value)}: #{inspect(reason)}"
    end
  end
end
