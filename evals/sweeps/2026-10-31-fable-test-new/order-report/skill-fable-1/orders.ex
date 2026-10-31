defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with the string keys `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  The report holds, for every customer, the total spent per currency across
  completed orders and the UTC date of their most recent order of any status,
  plus the five customers with the most completed orders.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2026-01-05T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2026-02-01T09:30:00+02:00", "status" => "completed"},
      ...>   %{"customer_id" => "c2", "amount" => "40.00", "currency" => "USD",
      ...>     "placed_at" => "2026-03-01T12:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("25.00")}
      iex> report.customers["c2"]
      %Reports.Orders.Customer{customer_id: "c2", totals: %{}, last_order_date: ~D[2026-03-01]}
      iex> report.top_customers
      [{"c1", 2}]

      iex> Reports.Orders.build([%{"customer_id" => "c1", "amount" => "abc"}])
      {:error, {:invalid_row, 1, {:invalid_field, "amount"}}}
  """

  defmodule Order do
    @moduledoc "One parsed order."

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

  defmodule Customer do
    @moduledoc "One customer's summary: completed spend per currency and last order date."

    @enforce_keys [:customer_id, :totals, :last_order_date]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            customer_id: String.t(),
            totals: %{String.t() => Decimal.t()},
            last_order_date: Date.t()
          }
  end

  @enforce_keys [:customers, :top_customers]
  defstruct @enforce_keys

  @type row :: %{optional(String.t()) => String.t()}
  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}
  @type error :: {:invalid_row, pos_integer(), field_error()}
  @type t :: %__MODULE__{
          customers: %{String.t() => Customer.t()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customer_count 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:error, {:invalid_row, row_number, reason}}` for the first row that
  lacks a field or holds one that cannot be parsed. Row numbers start at 1.
  """
  @spec build([row()]) :: {:ok, t()} | {:error, error()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows), do: parse_orders(Enum.with_index(rows, 1), [])

  defp parse_orders([], orders), do: {:ok, orders}

  defp parse_orders([{row, row_number} | rest], orders) do
    case parse_order(row) do
      {:ok, order} ->
        parse_orders(rest, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_row, row_number, reason}}
    end
  end

  defp parse_order(row) do
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

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(row) do
    with {:ok, text} <- string_field(row, "amount"), do: parse_amount(text)
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp placed_at_field(row) do
    with {:ok, text} <- string_field(row, "placed_at"), do: parse_placed_at(text)
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp status_field(row) do
    with {:ok, text} <- string_field(row, "status"), do: parse_status(text)
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_id, customer_orders)}
      end)

    %__MODULE__{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(customer_id, orders) do
    %Customer{
      customer_id: customer_id,
      totals: totals_by_currency(completed(orders)),
      last_order_date: last_order_date(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

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
    |> Enum.take(@top_customer_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
