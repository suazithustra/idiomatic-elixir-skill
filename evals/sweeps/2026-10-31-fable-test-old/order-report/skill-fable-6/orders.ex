defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each row is a string-keyed map with the keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Rows are validated and turned
  into `Reports.Orders.Order` structs before anything is summed, so a
  malformed row is reported with its position instead of skewing a total.
  """

  defmodule Order do
    @moduledoc false

    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys

    @type status :: :completed | :refunded | :pending
    @type t :: %__MODULE__{
            customer_id: String.t(),
            amount: Decimal.t(),
            currency: String.t(),
            placed_at: DateTime.t(),
            status: status()
          }
  end

  @top_customers_count 5

  @type row :: %{optional(String.t()) => term()}
  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_date: Date.t()
        }
  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }
  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}

  @doc """
  Builds the report for `rows`.

  The report has two parts:

    * `:customers` maps each customer id to the amount spent per currency
      across completed orders, and to the UTC date of the customer's most
      recent order of any status. A customer with no completed order has
      empty totals.
    * `:top_customers` lists up to five `{customer_id, completed_order_count}`
      pairs, most orders first, ties broken by customer id.

  Returns `{:error, {:invalid_row, line, reason}}` for the first row that lacks
  a field or holds a value that does not parse. Rows are counted from 1.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-02T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "7.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %{totals: %{"EUR" => Decimal.new("25.00")}, last_order_date: ~D[2024-03-05]}
      iex> report.top_customers
      [{"c1", 2}]

      iex> Reports.Orders.build([%{"customer_id" => "c1", "amount" => "abc"}])
      {:error, {:invalid_row, 1, {:invalid_field, "amount"}}}
  """
  @spec build([row()]) :: {:ok, report()} | {:error, {:invalid_row, pos_integer(), field_error()}}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{
      totals: totals_by_currency(completed(orders)),
      last_order_date: last_order_date(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} -> {currency, sum_amounts(currency_orders)} end)
  end

  defp sum_amounts(orders), do: Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))

  defp last_order_date(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))

  defp parse_orders(rows), do: parse_orders(rows, 1, [])

  defp parse_orders([], _line, orders), do: {:ok, orders}

  defp parse_orders([row | rest], line, orders) do
    case parse_order(row) do
      {:ok, order} -> parse_orders(rest, line + 1, [order | orders])
      {:error, reason} -> {:error, {:invalid_row, line, reason}}
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parsed_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parsed_field(row, "placed_at", &parse_placed_at/1),
         {:ok, status} <- parsed_field(row, "status", &parse_status/1) do
      order = %Order{
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
      {:ok, ""} -> {:error, {:missing_field, key}}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parsed_field(row, key, parse) do
    case string_field(row, key) do
      {:ok, text} -> parse_text(text, key, parse)
      {:error, _reason} = error -> error
    end
  end

  defp parse_text(text, key, parse) do
    case parse.(text) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  # Decimal.parse/1 also accepts "inf" and "nan", which must not reach a sum.
  defp parse_amount(text) do
    case Decimal.parse(text) do
      {%Decimal{coef: coef} = amount, ""} when is_integer(coef) -> {:ok, amount}
      {_amount, _rest} -> :error
      :error -> :error
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: :error
end
