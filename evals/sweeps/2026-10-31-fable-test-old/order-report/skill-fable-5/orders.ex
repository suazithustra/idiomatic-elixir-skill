defmodule Reports.Orders.Order do
  @moduledoc """
  One order, parsed from a string-keyed CSV row.
  """

  @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
  defstruct [:customer_id, :amount, :currency, :placed_at, :status]

  @type status :: :completed | :refunded | :pending

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: status()
        }

  @doc """
  Parses a CSV row into an order.

  Every key is required. The amount is a decimal string, `placed_at` an
  ISO 8601 datetime, and the status one of `"completed"`, `"refunded"` or
  `"pending"`.

  ## Examples

      iex> row = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "19.99",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2024-01-10T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> {:ok, order} = Reports.Orders.Order.parse(row)
      iex> {order.amount, order.status}
      {Decimal.new("19.99"), :completed}

      iex> Reports.Orders.Order.parse(%{"customer_id" => "c1"})
      {:error, :invalid_row}
  """
  @spec parse(map()) :: {:ok, t()} | {:error, :invalid_row | {:invalid_field, String.t()}}
  def parse(%{
        "customer_id" => customer_id,
        "amount" => amount,
        "currency" => currency,
        "placed_at" => placed_at,
        "status" => status
      }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_placed_at(placed_at),
         {:ok, status} <- parse_status(status) do
      order = %__MODULE__{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_at: placed_at,
        status: status
      }

      {:ok, order}
    end
  end

  def parse(_row), do: {:error, :invalid_row}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}
end

defmodule Reports.Orders.Report do
  @moduledoc """
  The report `Reports.Orders.build/1` produces.

  `customers` maps each customer id to what the customer spent per currency
  across completed orders and when the customer last placed an order of any
  status. `top_customers` lists the customers with the most completed orders,
  most first, as `{customer_id, completed_order_count}` pairs.
  """

  @enforce_keys [:customers, :top_customers]
  defstruct [:customers, :top_customers]

  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type t :: %__MODULE__{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.
  """

  alias Reports.Orders.Order
  alias Reports.Orders.Report

  @top_customers_count 5

  @doc """
  Builds the report for a list of CSV rows.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`; see `Reports.Orders.Order.parse/1`.
  Parsing stops at the first bad row and reports its 1-based position.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-01-10T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-02-01T09:30:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "40.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-05T12:00:00Z", "status" => "refunded"},
      ...>   %{"customer_id" => "c2", "amount" => "10.00", "currency" => "USD",
      ...>     "placed_at" => "2024-01-20T08:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %{spent: %{"EUR" => Decimal.new("25.00")}, last_order_at: ~U[2024-03-05 12:00:00Z]}
      iex> report.top_customers
      [{"c1", 2}, {"c2", 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_row, 1, :invalid_row}}
  """
  @spec build([map()]) :: {:ok, Report.t()} | {:error, {:invalid_row, pos_integer(), term()}}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, position}, {:ok, orders} ->
      case Order.parse(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_row, position, reason}}}
      end
    end)
  end

  defp summarize(orders) do
    %Report{
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
      spent: spent_per_currency(orders),
      last_order_at: orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime)
    }
  end

  defp spent_per_currency(orders) do
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
    |> Enum.take(@top_customers_count)
  end

  defp completed?(order), do: order.status == :completed
end
