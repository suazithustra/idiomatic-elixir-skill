defmodule Reports.Orders.Order do
  @moduledoc """
  One order after parsing and validation of a CSV row.
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

defmodule Reports.Orders.Customer do
  @moduledoc """
  The report line for one customer.

  `spent_by_currency` sums the amounts of the customer's completed orders, keyed
  by currency code. `last_order_on` is the UTC date of the customer's most recent
  order of any status.
  """

  @enforce_keys [:customer_id, :spent_by_currency, :last_order_on]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          customer_id: String.t(),
          spent_by_currency: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }
end

defmodule Reports.Orders.Report do
  @moduledoc """
  The order report.

  `customers` holds one `Reports.Orders.Customer` per customer id.
  `top_customers` lists the customers with the most completed orders, best
  first, as `{customer_id, completed_order_count}` pairs. Ties are broken by
  customer id.
  """

  @enforce_keys [:customers, :top_customers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          customers: %{String.t() => Reports.Orders.Customer.t()},
          top_customers: [{String.t(), pos_integer()}]
        }
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Rows are validated and turned into
  `Reports.Orders.Order` structs before anything is computed, so a malformed row
  is reported with its position instead of producing a wrong total.
  """

  alias Reports.Orders.Customer
  alias Reports.Orders.Order
  alias Reports.Orders.Report

  @top_customers_count 5

  @type row :: %{String.t() => String.t()}

  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}

  @type error :: {:invalid_row, pos_integer(), field_error()}

  @doc """
  Builds the report for `rows`.

  Returns `{:error, {:invalid_row, position, reason}}` for the first row that
  cannot be parsed, where `position` counts from 1 and `reason` is
  `{:missing_field, key}` or `{:invalid_field, key}`.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-05-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-06-01T10:00:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> Decimal.to_string(report.customers["c1"].spent_by_currency["EUR"])
      "19.99"
      iex> report.customers["c1"].last_order_on
      ~D[2024-06-01]
      iex> report.top_customers
      [{"c1", 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1", "amount" => "abc"}])
      {:error, {:invalid_row, 1, {:invalid_field, "amount"}}}

  """
  @spec build([row()]) :: {:ok, Report.t()} | {:error, error()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, report(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp report(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %Report{
      customers: customers(orders),
      top_customers: top_customers(completed)
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, customer(customer_id, customer_orders)}
    end)
  end

  defp customer(customer_id, customer_orders) do
    last_placed_at = Enum.max_by(customer_orders, & &1.placed_at, DateTime).placed_at

    %Customer{
      customer_id: customer_id,
      spent_by_currency: spent_by_currency(customer_orders),
      last_order_on: DateTime.to_date(last_placed_at)
    }
  end

  defp spent_by_currency(customer_orders) do
    customer_orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(completed) do
    completed
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers_count)
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_row/2)
  end

  defp parse_row({row, position}, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, reason} -> {:halt, {:error, {:invalid_row, position, reason}}}
    end
  end

  defp parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
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
