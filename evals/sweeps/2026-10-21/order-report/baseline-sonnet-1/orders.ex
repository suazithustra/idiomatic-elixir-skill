defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed order maps.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_at: DateTime.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report.

  `:customers` maps each customer id to the total spent per currency across
  completed orders, the number of completed orders, and the time of their most
  recent order (any status). `:top_customers` lists up to #{@top_n}
  `{customer_id, completed_count}` pairs, most completed orders first, ties
  broken by customer id.

  Returns `{:error, {:invalid_order, order, reason}}` for the first malformed
  order.
  """
  @spec build([map()]) :: {:ok, t()} | {:error, {:invalid_order, map(), term()}}
  def build(orders) do
    orders
    |> Enum.reduce_while({:ok, %{}}, fn order, {:ok, acc} ->
      case parse(order) do
        {:ok, parsed} -> {:cont, {:ok, add_order(acc, parsed)}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, order, reason}}}
      end
    end)
    |> case do
      {:ok, customers} -> {:ok, %{customers: customers, top_customers: top_customers(customers)}}
      {:error, _} = error -> error
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
         status: status
       }}
    end
  end

  defp parse(_order), do: {:error, :missing_fields}

  defp parse_amount(string) when is_binary(string) do
    case Decimal.parse(string) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, {:bad_amount, string}}
    end
  end

  defp parse_amount(other), do: {:error, {:bad_amount, other}}

  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, :missing_offset} ->
        # No offset in the string: treat it as UTC.
        with {:ok, naive} <- NaiveDateTime.from_iso8601(string) do
          {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_datetime(other), do: {:error, {:bad_datetime, other}}

  defp add_order(customers, order) do
    initial = %{totals: %{}, completed_count: 0, last_order_at: order.placed_at}

    Map.update(customers, order.customer_id, apply_order(initial, order), &apply_order(&1, order))
  end

  defp apply_order(summary, order) do
    summary
    |> Map.update!(:last_order_at, &latest(&1, order.placed_at))
    |> add_if_completed(order)
  end

  defp add_if_completed(summary, %{status: "completed"} = order) do
    %{
      summary
      | totals: Map.update(summary.totals, order.currency, order.amount, &Decimal.add(&1, order.amount)),
        completed_count: summary.completed_count + 1
    }
  end

  defp add_if_completed(summary, _order), do: summary

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed_count: count}} -> {id, count} end)
    |> Enum.reject(fn {_id, count} -> count == 0 end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end
end
