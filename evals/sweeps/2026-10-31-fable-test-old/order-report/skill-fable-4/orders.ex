defmodule Reports.Orders.Customer do
  @moduledoc """
  One customer's summary: `totals` maps each currency code to the sum of the
  customer's completed orders in that currency, and `last_ordered_on` is the
  UTC date of the customer's most recent order of any status.
  """

  @enforce_keys [:totals, :last_ordered_on]
  defstruct [:totals, :last_ordered_on]

  @type t :: %__MODULE__{
          totals: %{String.t() => Decimal.t()},
          last_ordered_on: Date.t()
        }
end

defmodule Reports.Orders.Report do
  @moduledoc """
  The report `Reports.Orders.build/1` returns.

  `customers` maps each customer id to its `Reports.Orders.Customer` summary.
  `top_customers` lists `{customer_id, completed_order_count}` pairs for the
  customers with the most completed orders, most first.
  """

  alias Reports.Orders.Customer

  @enforce_keys [:customers, :top_customers]
  defstruct [:customers, :top_customers]

  @type t :: %__MODULE__{
          customers: %{String.t() => Customer.t()},
          top_customers: [{String.t(), pos_integer()}]
        }
end

defmodule Reports.Orders.InvalidOrder do
  @moduledoc """
  Raised, or returned as the error reason, when an order row is missing a field
  or holds a value that cannot be parsed.
  """

  defexception [:field, :reason, :value]

  @type t :: %__MODULE__{
          field: String.t(),
          reason: :missing | :invalid,
          value: term()
        }

  @impl true
  def message(%__MODULE__{reason: :missing} = error) do
    "order is missing the #{inspect(error.field)} field"
  end

  def message(%__MODULE__{reason: :invalid} = error) do
    "order has an invalid #{inspect(error.field)} field: #{inspect(error.value)}"
  end
end

defmodule Reports.Orders.Order do
  @moduledoc false

  @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
  defstruct [:customer_id, :amount, :currency, :placed_at, :status]

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: :completed | :refunded | :pending
        }
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a string-keyed map with the fields `"customer_id"`, `"amount"`
  (a decimal string such as `"19.99"`), `"currency"` (an ISO 4217 code such as
  `"EUR"`), `"placed_at"` (an ISO 8601 datetime) and `"status"` (`"completed"`,
  `"refunded"` or `"pending"`).

  The report holds, per customer, the total spent per currency across completed
  orders and the date of the most recent order of any status, plus the five
  customers with the most completed orders.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-01-10T09:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-02-01T09:00:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("19.99")}
      iex> report.customers["c1"].last_ordered_on
      ~D[2026-02-01]
      iex> report.top_customers
      [{"c1", 1}]

  """

  alias Reports.Orders.Customer
  alias Reports.Orders.InvalidOrder
  alias Reports.Orders.Order
  alias Reports.Orders.Report

  @top_count 5

  @doc """
  Builds the report for `rows`, a list of string-keyed order maps.

  Returns `{:error, %Reports.Orders.InvalidOrder{}}` on the first row that is
  missing a field or holds a value that cannot be parsed.
  """
  @spec build([map()]) :: {:ok, Report.t()} | {:error, InvalidOrder.t()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Same as `build/1`, but raises `Reports.Orders.InvalidOrder` on bad input.
  """
  @spec build!([map()]) :: Report.t()
  def build!(rows) do
    case build(rows) do
      {:ok, report} -> report
      {:error, error} -> raise error
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rows], orders) do
    case parse_order(row) do
      {:ok, order} -> parse_orders(rows, [order | orders])
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parsed_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parsed_field(row, "placed_at", &parse_datetime/1),
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
      {:ok, text} when is_binary(text) and text != "" -> {:ok, text}
      {:ok, value} -> {:error, %InvalidOrder{field: key, reason: :invalid, value: value}}
      :error -> {:error, %InvalidOrder{field: key, reason: :missing}}
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
      :error -> {:error, %InvalidOrder{field: key, reason: :invalid, value: text}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> :error
      :error -> :error
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: :error

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %Report{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    %Customer{totals: totals_by_currency(orders), last_ordered_on: last_ordered_on(orders)}
  end

  defp totals_by_currency(orders) do
    orders
    |> completed()
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_ordered_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  # Ties are broken by customer id so the list is the same on every run.
  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
