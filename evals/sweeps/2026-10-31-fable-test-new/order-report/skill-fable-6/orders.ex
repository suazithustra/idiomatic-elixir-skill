defmodule Reports.Orders.Order do
  @moduledoc "One parsed order row."

  @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: :completed | :refunded | :pending
        }
end

defmodule Reports.Orders.CustomerSummary do
  @moduledoc """
  One customer's line in the report.

  `spent_by_currency` sums the completed orders only; `last_order_on` is the
  date of the customer's most recent order in any status.
  """

  @enforce_keys [:spent_by_currency, :last_order_on]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          spent_by_currency: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }
end

defmodule Reports.Orders.Report do
  @moduledoc """
  The finished report.

  `customers` is keyed by customer id. `top_customers` lists up to five
  `{customer_id, completed_order_count}` pairs, most orders first, ties broken
  by customer id.
  """

  @enforce_keys [:customers, :top_customers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          customers: %{String.t() => Reports.Orders.CustomerSummary.t()},
          top_customers: [{String.t(), pos_integer()}]
        }
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a string-keyed map with `"customer_id"`, `"amount"` (a decimal
  string), `"currency"`, `"placed_at"` (ISO 8601) and `"status"` (`"completed"`,
  `"refunded"` or `"pending"`). Rows are parsed into `Reports.Orders.Order`
  structs first, so a malformed row is reported with its line number instead of
  producing a wrong total.
  """

  alias Reports.Orders.CustomerSummary
  alias Reports.Orders.Order
  alias Reports.Orders.Report

  @top_customer_count 5

  @typedoc "A row as the CSV parser emits it."
  @type row :: %{optional(String.t()) => String.t()}

  @type reason ::
          {:invalid_row, pos_integer(),
           :missing_fields
           | {:invalid_amount, String.t()}
           | {:invalid_placed_at, String.t()}
           | {:unknown_status, String.t()}}

  @doc """
  Builds the report for `rows`.

  Returns `{:error, {:invalid_row, line, reason}}` for the first row that
  cannot be parsed, where `line` counts rows from 1.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-01-10T09:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.00", "currency" => "USD",
      ...>     "placed_at" => "2024-02-01T09:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].last_order_on
      ~D[2024-02-01]
      iex> report.top_customers
      [{"c1", 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_row, 1, :missing_fields}}
  """
  @spec build([row()]) :: {:ok, Report.t()} | {:error, reason()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, 1, [])

  defp parse_orders([], _line, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rows], line, orders) do
    case parse_order(row) do
      {:ok, order} ->
        parse_orders(rows, line + 1, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_row, line, reason}}
    end
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_placed_at(placed_at),
         {:ok, status} <- parse_status(status) do
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

  defp parse_order(_row), do: {:error, :missing_fields}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_amount, text}}

      :error ->
        {:error, {:invalid_amount, text}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_placed_at, text}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %Report{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    %CustomerSummary{
      spent_by_currency: spent_by_currency(completed(orders)),
      last_order_on: last_order_on(orders)
    }
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} -> {currency, sum_amounts(orders)} end)
  end

  defp sum_amounts(orders), do: Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))

  defp last_order_on(orders) do
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

  defp completed(orders), do: Enum.filter(orders, &completed?/1)

  defp completed?(%Order{status: :completed}), do: true
  defp completed?(%Order{}), do: false
end
