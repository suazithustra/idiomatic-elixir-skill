defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from orders as a CSV parser emits them.

  Each row is a map with the string keys `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  The report lists, for every customer, the total spent per currency across
  completed orders and the UTC date of their most recent order of any status,
  plus the five customers with the most completed orders.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.01",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-02T09:30:00+02:00",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "40.00",
      ...>     "currency" => "USD",
      ...>     "placed_at" => "2026-03-05T12:00:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %{spent: %{"EUR" => Decimal.new("25.00")}, last_ordered_on: ~D[2026-03-05]}
      iex> report.top_customers
      [%{customer_id: "c1", completed_orders: 2}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:missing_field, "amount"}}
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
            status: status
          }
  end

  @top_customer_count 5

  @typedoc "Totals per currency over completed orders and the UTC date of the latest order."
  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          last_ordered_on: Date.t()
        }

  @typedoc "A customer's rank entry, with the number of completed orders."
  @type top_customer :: %{customer_id: String.t(), completed_orders: non_neg_integer()}

  @type report :: %{
          customers: %{String.t() => customer_summary},
          top_customers: [top_customer]
        }

  @type error ::
          {:invalid_row, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Builds the report from parsed CSV rows.

  Stops at the first row that cannot be parsed and returns why: a row that is
  not a map, a required column that is absent, or a value that does not parse
  as a decimal, an ISO 8601 datetime or a known status.
  """
  @spec build([map()]) :: {:ok, report} | {:error, error}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows, []) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rest, [order | orders])
    end
  end

  defp parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- amount_field(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- placed_at_field(row),
         {:ok, status} <- status_field(row) do
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

  defp parse_order(row), do: {:error, {:invalid_row, row}}

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(row) do
    with {:ok, text} <- string_field(row, "amount") do
      parse_amount(text)
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp placed_at_field(row) do
    with {:ok, text} <- string_field(row, "placed_at") do
      parse_placed_at(text)
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp status_field(row) do
    with {:ok, text} <- string_field(row, "status") do
      parse_status(text)
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      spent: spent_by_currency(completed(orders)),
      last_ordered_on: DateTime.to_date(latest.placed_at)
    }
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
    |> Enum.map(&rank_entry/1)
  end

  defp rank_entry({customer_id, count}), do: %{customer_id: customer_id, completed_orders: count}

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
