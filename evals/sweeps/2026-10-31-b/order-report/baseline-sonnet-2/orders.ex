defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from parsed order maps.

  Each order is a map with string keys: "customer_id", "amount",
  "currency", "placed_at" (ISO 8601) and "status".
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t(),
          completed_count: non_neg_integer()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns `%{customers: ..., top_customers: ...}`.

  * `customers` maps each customer id to the total spent per currency
    (completed orders only), the date of their most recent order (any
    status) and their completed order count.
  * `top_customers` is the top #{@top_n} `{customer_id, completed_count}`
    pairs, highest count first, ties broken by customer id.

  Raises if an order has an invalid amount or timestamp.
  """
  @spec build([map()]) :: t()
  def build(orders) do
    customers =
      orders
      |> Enum.reduce(%{}, &add_order/2)
      |> Map.new(fn {id, acc} -> {id, finalize(acc)} end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp add_order(order, acc) do
    %{"customer_id" => id, "placed_at" => placed_at, "status" => status} = order
    placed_at = parse_datetime!(placed_at)

    Map.update(acc, id, new_entry(order, placed_at), fn entry ->
      entry
      |> Map.update!(:last_order_at, &latest(&1, placed_at))
      |> add_completed(order, status)
    end)
  end

  defp new_entry(%{"status" => status} = order, placed_at) do
    add_completed(%{totals: %{}, completed_count: 0, last_order_at: placed_at}, order, status)
  end

  defp add_completed(entry, %{"amount" => amount, "currency" => currency}, "completed") do
    amount = Decimal.new(amount)

    entry
    |> Map.update!(:totals, &Map.update(&1, currency, amount, fn sum -> Decimal.add(sum, amount) end))
    |> Map.update!(:completed_count, &(&1 + 1))
  end

  defp add_completed(entry, _order, _status), do: entry

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp parse_datetime!(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(string)}: #{reason}"
    end
  end

  defp finalize(%{last_order_at: at} = entry) do
    entry
    |> Map.delete(:last_order_at)
    |> Map.put(:last_order_on, DateTime.to_date(at))
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed_count: count}} -> {id, count} end)
    |> Enum.filter(fn {_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end
end
