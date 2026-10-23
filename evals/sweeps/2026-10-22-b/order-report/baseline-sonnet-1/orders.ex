defmodule Reports.Orders do
  @moduledoc """
  Builds a report from parsed order maps (string keys).

  Only `"completed"` orders count towards totals, the last-order date and the
  top-customers ranking. Rows that cannot be parsed are returned under
  `:errors` rather than crashing the whole report.
  """

  @type order :: %{optional(String.t()) => String.t()}

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t(),
          completed_count: pos_integer()
        }

  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}],
          errors: [{order(), term()}]
        }

  @top_n 5

  @spec build([order()]) :: t()
  def build(orders) do
    {parsed, errors} =
      orders
      |> Enum.filter(&(&1["status"] == "completed"))
      |> Enum.reduce({[], []}, fn order, {ok, bad} ->
        case parse(order) do
          {:ok, entry} -> {[entry | ok], bad}
          {:error, reason} -> {ok, [{order, reason} | bad]}
        end
      end)

    customers =
      parsed
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {id, entries} -> {id, customer_report(entries)} end)

    %{
      customers: customers,
      top_customers: top_customers(customers),
      errors: Enum.reverse(errors)
    }
  end

  defp parse(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at, _offset} <- DateTime.from_iso8601(placed_at) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_on: DateTime.to_date(placed_at)
       }}
    end
  end

  defp parse(_order), do: {:error, :missing_fields}

  defp parse_amount(string) do
    case Decimal.parse(string) do
      {amount, ""} -> {:ok, amount}
      _ -> {:error, :invalid_amount}
    end
  end

  defp customer_report(entries) do
    %{
      totals:
        Enum.reduce(entries, %{}, fn %{currency: currency, amount: amount}, acc ->
          Map.update(acc, currency, amount, &Decimal.add(&1, amount))
        end),
      last_order_on: entries |> Enum.map(& &1.placed_on) |> Enum.max(Date),
      completed_count: length(entries)
    }
  end

  # Ties are broken by customer id so the ranking is deterministic.
  defp top_customers(customers) do
    customers
    |> Enum.map(fn {id, %{completed_count: count}} -> {id, count} end)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_n)
  end
end
