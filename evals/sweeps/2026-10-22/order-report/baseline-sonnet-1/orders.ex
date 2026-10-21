defmodule Reports.Orders do
  @moduledoc """
  Builds a report from a list of order maps (string keys, as produced by a CSV parser).

  The report is a map:

    * `:customers` - `%{customer_id => %{totals: %{currency => Decimal.t()}, last_order_on: Date.t()}}`.
      `totals` only counts completed orders. `last_order_on` is the date of the
      customer's latest order of any status.
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples, most
      completed orders first. Ties are broken by customer id.

  Malformed amounts or timestamps raise `ArgumentError`.
  """

  @top_n 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @spec build([map()]) :: t()
  def build(orders) do
    summaries =
      orders
      |> Enum.map(&normalize/1)
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {id, rows} -> {id, summarize(rows)} end)

    %{
      customers: Map.new(summaries, fn {id, summary} -> {id, Map.delete(summary, :completed_count)} end),
      top_customers: top_customers(summaries)
    }
  end

  defp normalize(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    %{
      customer_id: customer_id,
      amount: parse_amount!(amount),
      currency: currency,
      placed_on: parse_date!(placed_at),
      completed?: status == "completed"
    }
  end

  defp summarize(rows) do
    completed = Enum.filter(rows, & &1.completed?)

    %{
      totals:
        Enum.reduce(completed, %{}, fn %{currency: currency, amount: amount}, acc ->
          Map.update(acc, currency, amount, &Decimal.add(&1, amount))
        end),
      completed_count: length(completed),
      last_order_on: rows |> Enum.map(& &1.placed_on) |> Enum.max(Date)
    }
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed_count: count}} -> {id, count} end)
    |> Enum.filter(fn {_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end

  defp parse_amount!(amount) do
    case Decimal.parse(amount) do
      {decimal, ""} -> decimal
      _ -> raise ArgumentError, "invalid amount: #{inspect(amount)}"
    end
  end

  defp parse_date!(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> DateTime.to_date(datetime)
      {:error, reason} -> raise ArgumentError, "invalid placed_at #{inspect(placed_at)}: #{reason}"
    end
  end
end
