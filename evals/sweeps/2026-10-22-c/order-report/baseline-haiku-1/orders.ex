defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report and a top-customers ranking from parsed order rows.

  Each order is a map with string keys:

    * `"customer_id"`
    * `"amount"` - a decimal string such as `"19.99"`
    * `"currency"` - such as `"EUR"` or `"USD"`
    * `"placed_at"` - an ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are kept as integer minor units (cents) so sums are exact without
  depending on the `decimal` package.

  Only `"completed"` orders count towards spend and the top-customers ranking.
  The most recent order date considers every order, whatever its status.
  """

  @top_count 5

  @type customer_report :: %{
          spent: %{String.t() => integer()},
          completed_count: non_neg_integer(),
          last_order_date: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @spec build([map()]) :: report()
  def build(orders) when is_list(orders) do
    customers =
      orders
      |> Enum.group_by(& &1["customer_id"])
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, customer_report(customer_orders)}
      end)

    top_customers =
      customers
      |> Enum.map(fn {customer_id, report} -> {customer_id, report.completed_count} end)
      |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
      |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
      |> Enum.take(@top_count)

    %{customers: customers, top_customers: top_customers}
  end

  defp customer_report(orders) do
    completed = Enum.filter(orders, &completed?/1)

    %{
      spent: spent_by_currency(completed),
      completed_count: length(completed),
      last_order_date: orders |> Enum.map(&placed_date/1) |> Enum.max(Date)
    }
  end

  defp spent_by_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1["currency"], &parse_cents(&1["amount"]))
    |> Map.new(fn {currency, amounts} -> {currency, Enum.sum(amounts)} end)
  end

  defp completed?(%{"status" => "completed"}), do: true
  defp completed?(_order), do: false

  defp placed_date(%{"placed_at" => placed_at}) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> DateTime.to_date(datetime)
      {:error, _reason} -> raise ArgumentError, "invalid placed_at: #{inspect(placed_at)}"
    end
  end

  defp parse_cents(amount) when is_binary(amount) do
    {whole, fraction} =
      case String.split(amount, ".", parts: 2) do
        [whole] -> {whole, "00"}
        [whole, fraction] -> {whole, String.pad_trailing(fraction, 2, "0")}
      end

    if String.match?(whole, ~r/\A-?\d+\z/) and String.match?(fraction, ~r/\A\d{2}\z/) do
      sign = if String.starts_with?(whole, "-"), do: -1, else: 1
      String.to_integer(whole) * 100 + sign * String.to_integer(fraction)
    else
      raise ArgumentError, "invalid amount: #{inspect(amount)}"
    end
  end
end
