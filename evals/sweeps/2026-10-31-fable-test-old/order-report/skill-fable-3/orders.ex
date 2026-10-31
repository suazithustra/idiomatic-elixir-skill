defmodule Reports.Orders.Order do
  @moduledoc """
  An order parsed from one CSV row.
  """

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

defmodule Reports.Orders.CustomerSummary do
  @moduledoc """
  One customer's total spent per currency across completed orders, and the date
  of their most recent order of any status.
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
  A summary per customer and the customers with the most completed orders,
  as `{customer_id, completed_order_count}` pairs, most orders first.
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
  Builds a report from orders parsed out of a CSV file.

  Each row is a map with the string keys `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"` (an ISO 4217 code such as `"EUR"`),
  `"placed_at"` (an ISO 8601 datetime) and `"status"` (`"completed"`,
  `"refunded"` or `"pending"`).
  """

  alias Reports.Orders.CustomerSummary
  alias Reports.Orders.Order
  alias Reports.Orders.Report

  @top_customers 5

  @type row :: %{String.t() => String.t()}
  @type error :: {:missing_field, String.t()} | {:invalid_field, String.t()}

  @doc """
  Builds the report for `rows`.

  Returns the error for the first row that cannot be parsed, see `parse_order/1`.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %Reports.Orders.CustomerSummary{
        spent_by_currency: %{"EUR" => Decimal.new("19.99")},
        last_order_on: ~D[2024-03-05]
      }
      iex> report.top_customers
      [{"c1", 1}]

  """
  @spec build([row()]) :: {:ok, Report.t()} | {:error, error()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Parses one CSV row into an `Reports.Orders.Order`.

  Returns `{:error, {:missing_field, key}}` when the row lacks a column and
  `{:error, {:invalid_field, key}}` when a value is empty or cannot be parsed.

  ## Examples

      iex> row = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "19.99",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2024-03-01T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> {:ok, order} = Reports.Orders.parse_order(row)
      iex> order.status
      :completed
      iex> Reports.Orders.parse_order(%{row | "amount" => "19.99 EUR"})
      {:error, {:invalid_field, "amount"}}
      iex> Reports.Orders.parse_order(Map.delete(row, "status"))
      {:error, {:missing_field, "status"}}

  """
  @spec parse_order(row()) :: {:ok, Order.t()} | {:error, error()}
  def parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parse_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- parse_field(row, "currency", &parse_currency/1),
         {:ok, placed_at} <- parse_field(row, "placed_at", &parse_datetime/1),
         {:ok, status} <- parse_field(row, "status", &parse_status/1) do
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

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, &collect_order/2)
  end

  defp collect_order(row, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp summarize(orders) do
    %Report{
      customers: summarize_customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %CustomerSummary{
      spent_by_currency: spent_by_currency(orders),
      last_order_on: DateTime.to_date(latest.placed_at)
    }
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers)
  end

  defp completed?(%Order{status: :completed}), do: true
  defp completed?(%Order{}), do: false

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_field(row, key, parse) do
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

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> :error
      :error -> :error
    end
  end

  defp parse_currency(code) do
    if Regex.match?(~r/\A[A-Z]{3}\z/, code), do: {:ok, code}, else: :error
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: :error
end
