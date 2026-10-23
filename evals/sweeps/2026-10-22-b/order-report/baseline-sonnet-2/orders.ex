defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from CSV-parsed order maps.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` (ISO 8601) and `"status"`.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t(),
          completed_orders: non_neg_integer()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns `%{customers: ..., top_customers: ...}`.

  * `customers` maps each customer id to its per-currency totals over
    completed orders, the datetime of its most recent order (any status),
    and its completed order count.
  * `top_customers` is the top 5 `{customer_id, completed_count}` pairs,
    ordered by count descending, then customer id.

  Raises `ArgumentError` on an unparseable amount or datetime.
  """
  @spec build([map()]) :: t()
  def build(orders) do
    customers = Enum.reduce(orders, %{}, &add_order/2)

    top_customers =
      customers
      |> Enum.map(fn {id, %{completed_orders: n}} -> {id, n} end)
      |> Enum.reject(fn {_id, n} -> n == 0 end)
      |> Enum.sort_by(fn {id, n} -> {-n, id} end)
      |> Enum.take(@top_n)

    %{customers: customers, top_customers: top_customers}
  end

  defp add_order(order, customers) do
    %{"customer_id" => id, "placed_at" => placed_at} = order
    placed_at = parse_datetime!(placed_at)

    Map.update(customers, id, new_summary(order, placed_at), fn summary ->
      summary
      |> Map.update!(:last_order_at, &latest(&1, placed_at))
      |> add_completed(order)
    end)
  end

  defp new_summary(order, placed_at) do
    add_completed(%{totals: %{}, last_order_at: placed_at, completed_orders: 0}, order)
  end

  defp add_completed(summary, %{"status" => "completed"} = order) do
    %{"amount" => amount, "currency" => currency} = order
    amount = parse_decimal!(amount)

    %{
      summary
      | totals: Map.update(summary.totals, currency, amount, &Decimal.add(&1, amount)),
        completed_orders: summary.completed_orders + 1
    }
  end

  defp add_completed(summary, _order), do: summary

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp parse_datetime!(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(string)}: #{reason}"
    end
  end

  defp parse_decimal!(string) do
    case Decimal.parse(string) do
      {decimal, ""} -> decimal
      _ -> raise ArgumentError, "invalid amount #{inspect(string)}"
    end
  end
end
