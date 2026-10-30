defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed order maps.

  Each order is a map with string keys: "customer_id", "amount", "currency",
  "placed_at" (ISO 8601) and "status".
  """

  @top_n 5

  @type order :: %{optional(String.t()) => String.t()}

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_date: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report.

  `:customers` maps each customer id to the total spent per currency across
  completed orders and the date of their most recent order (any status).
  `:top_customers` lists up to five `{customer_id, completed_count}` pairs,
  highest count first, ties broken by customer id.

  Returns `{:error, {:invalid_order, order, reason}}` for the first malformed order.
  """
  @spec build([order()]) :: {:ok, t()} | {:error, {:invalid_order, order(), term()}}
  def build(orders) do
    result =
      Enum.reduce_while(orders, {:ok, %{}}, fn order, {:ok, stats} ->
        case parse(order) do
          {:ok, parsed} -> {:cont, {:ok, add(stats, parsed)}}
          {:error, reason} -> {:halt, {:error, {:invalid_order, order, reason}}}
        end
      end)

    with {:ok, stats} <- result do
      {:ok, finish(stats)}
    end
  end

  defp parse(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at, _offset} <- DateTime.from_iso8601(placed_at) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse(_order), do: {:error, :missing_fields}

  defp parse_amount(string) do
    case Decimal.parse(string) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, :invalid_amount}
    end
  end

  defp add(stats, order) do
    entry = Map.get(stats, order.customer_id, %{totals: %{}, completed: 0, last: nil})

    entry =
      entry
      |> update_last(order.placed_at)
      |> update_completed(order)

    Map.put(stats, order.customer_id, entry)
  end

  defp update_last(%{last: nil} = entry, placed_at), do: %{entry | last: placed_at}

  defp update_last(%{last: last} = entry, placed_at) do
    if DateTime.compare(placed_at, last) == :gt, do: %{entry | last: placed_at}, else: entry
  end

  defp update_completed(entry, %{status: "completed"} = order) do
    totals =
      Map.update(entry.totals, order.currency, order.amount, &Decimal.add(&1, order.amount))

    %{entry | totals: totals, completed: entry.completed + 1}
  end

  defp update_completed(entry, _order), do: entry

  defp finish(stats) do
    customers =
      Map.new(stats, fn {id, entry} ->
        {id, %{totals: entry.totals, last_order_date: DateTime.to_date(entry.last)}}
      end)

    top_customers =
      stats
      |> Enum.map(fn {id, entry} -> {id, entry.completed} end)
      |> Enum.filter(fn {_id, count} -> count > 0 end)
      |> Enum.sort_by(fn {id, count} -> {-count, id} end)
      |> Enum.take(@top_n)

    %{customers: customers, top_customers: top_customers}
  end
end
