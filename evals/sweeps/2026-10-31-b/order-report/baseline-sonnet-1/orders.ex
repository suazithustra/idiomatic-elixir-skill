defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed order maps.

  Each order is a map with string keys: `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` (ISO 8601) and `"status"`.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}],
          invalid: [{map(), atom()}]
        }

  @doc """
  Returns a report with:

    * `:customers` - per customer, the total spent per currency across
      completed orders, the number of completed orders, and the date of the
      most recent order (any status)
    * `:top_customers` - up to 5 `{customer_id, completed_count}` tuples,
      highest count first, ties broken by customer id
    * `:invalid` - orders that could not be parsed, with the reason
  """
  @spec build([map()]) :: report()
  def build(orders) do
    {parsed, invalid} =
      Enum.reduce(orders, {[], []}, fn order, {ok, bad} ->
        case parse(order) do
          {:ok, parsed} -> {[parsed | ok], bad}
          {:error, reason} -> {ok, [{order, reason} | bad]}
        end
      end)

    customers =
      parsed
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {id, orders} -> {id, summarize(orders)} end)

    %{
      customers: customers,
      top_customers: top_customers(customers),
      invalid: Enum.reverse(invalid)
    }
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == "completed"))

    totals =
      Enum.reduce(completed, %{}, fn %{currency: currency, amount: amount}, acc ->
        Map.update(acc, currency, amount, &Decimal.add(&1, amount))
      end)

    %{
      totals: totals,
      completed_count: length(completed),
      last_order_on: orders |> Enum.map(& &1.placed_on) |> Enum.max(Date)
    }
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed_count: count}} -> {id, count} end)
    |> Enum.reject(fn {_id, count} -> count == 0 end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end

  defp parse(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_on} <- parse_date(placed_at) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_on: placed_on,
         status: status
       }}
    end
  end

  defp parse(_order), do: {:error, :missing_fields}

  defp parse_amount(string) when is_binary(string) do
    case Decimal.parse(string) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp parse_date(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, :missing_offset} -> parse_naive_date(string)
      {:error, _} -> {:error, :invalid_placed_at}
    end
  end

  defp parse_date(_), do: {:error, :invalid_placed_at}

  defp parse_naive_date(string) do
    case NaiveDateTime.from_iso8601(string) do
      {:ok, naive} -> {:ok, NaiveDateTime.to_date(naive)}
      {:error, _} -> {:error, :invalid_placed_at}
    end
  end
end
