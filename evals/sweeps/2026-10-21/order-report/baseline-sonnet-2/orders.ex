defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from CSV-parsed order maps.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (decimal
  string), `"currency"`, `"placed_at"` (ISO 8601 datetime) and `"status"`.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report.

  * `:customers` maps each customer id to the total spent per currency
    (completed orders only) and the date of their most recent order. The date
    considers orders of every status and is taken in UTC.
  * `:top_customers` lists up to #{@top_n} `{customer_id, completed_count}`
    pairs, highest count first, ties broken by customer id.

  Returns `{:error, {:invalid_order, order, reason}}` for the first malformed
  order.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {:invalid_order, map(), atom()}}
  def build(orders) do
    with {:ok, parsed} <- parse_all(orders) do
      {:ok, %{customers: customer_summaries(parsed), top_customers: top_customers(parsed)}}
    end
  end

  defp parse_all(orders) do
    orders
    |> Enum.reduce_while({:ok, []}, fn order, {:ok, acc} ->
      case parse(order) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, order, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
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
         {:ok, placed_at} <- parse_datetime(placed_at) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         completed?: status == "completed"
       }}
    end
  end

  defp parse(_order), do: {:error, :missing_fields}

  defp parse_amount(string) when is_binary(string) do
    case Decimal.parse(string) do
      {amount, ""} -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> {:error, :invalid_placed_at}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_placed_at}

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      last_order_on =
        customer_orders
        |> Enum.map(& &1.placed_at)
        |> Enum.max(DateTime)
        |> DateTime.to_date()

      totals =
        for %{completed?: true} = order <- customer_orders, reduce: %{} do
          acc -> Map.update(acc, order.currency, order.amount, &Decimal.add(&1, order.amount))
        end

      {customer_id, %{totals: totals, last_order_on: last_order_on}}
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(& &1.completed?)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_n)
  end
end
