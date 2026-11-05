defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from order rows.

  Rows come from a CSV parser as maps with string keys: `"customer_id"`,
  `"amount"` (a decimal string such as `"19.99"`), `"currency"`, `"placed_at"`
  (an ISO 8601 datetime), and `"status"` (`"completed"`, `"refunded"` or
  `"pending"`).

  Spending totals count completed orders only. The last order date counts
  every order, whatever its status.
  """

  @top_count 5

  @typedoc "Spending totals and last order date for one customer."
  @type summary :: %{
          completed_count: non_neg_integer(),
          totals: %{String.t() => Decimal.t()},
          last_placed_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from parsed order rows.

  Returns `{:ok, report}`. `report.customers` maps each customer ID to a
  summary with `:completed_count`, `:totals` (currency to `Decimal`) and
  `:last_placed_at`. `report.top_customers` lists up to five
  `{customer_id, completed_count}` tuples, most completed orders first, with
  ties broken by customer ID.

  Returns `{:error, {:invalid_row, line, reason}}` for the first row that is
  missing a field or holds a malformed value. `line` counts from 1.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "10.00", "currency" => "EUR",
      ...>     "placed_at" => "2026-01-02T10:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.top_customers
      [{"c1", 1}]

  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_rows(rows, 1, []) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_rows([], _line, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_rows([row | rest], line, orders) do
    case parse_row(row) do
      {:ok, order} ->
        parse_rows(rest, line + 1, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_row, line, reason}}
    end
  end

  defp parse_row(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parse_amount(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parse_placed_at(row),
         {:ok, status} <- parse_status(row) do
      order = %{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_at: placed_at,
        status: status
      }

      {:ok, order}
    end
  end

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_blank -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_amount(row) do
    with {:ok, text} <- string_field(row, "amount") do
      case Decimal.parse(text) do
        {%Decimal{coef: coef} = amount, ""} when is_integer(coef) -> {:ok, amount}
        _unparsed -> {:error, {:invalid_field, "amount"}}
      end
    end
  end

  defp parse_placed_at(row) do
    with {:ok, text} <- string_field(row, "placed_at") do
      case DateTime.from_iso8601(text) do
        {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
        {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
      end
    end
  end

  defp parse_status(row) do
    with {:ok, text} <- string_field(row, "status") do
      status_from_text(text)
    end
  end

  defp status_from_text("completed"), do: {:ok, :completed}
  defp status_from_text("refunded"), do: {:ok, :refunded}
  defp status_from_text("pending"), do: {:ok, :pending}
  defp status_from_text(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))
    last_placed_at = orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime)

    %{
      completed_count: Enum.count(completed),
      totals: totals_by_currency(completed),
      last_placed_at: last_placed_at
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum_amounts(amounts)} end)
  end

  defp sum_amounts(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
