defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from a list of orders as a CSV parser produces them.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"` (`"EUR"`, `"USD"`, ...), `"placed_at"`
  (an ISO 8601 datetime) and `"status"` (`"completed"`, `"refunded"` or
  `"pending"`). Rows are parsed into `Reports.Orders.Order` structs first, so a
  malformed row is reported with its position and field instead of producing a
  wrong report.

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
      iex> report.customers["c1"].completed_totals
      %{"EUR" => Decimal.new("19.99")}
      iex> report.customers["c1"].last_placed_at
      ~U[2024-06-01 10:00:00Z]
      iex> report.top_customers
      [{"c1", 1}]
  """

  alias Reports.Orders.CustomerSummary
  alias Reports.Orders.InvalidOrder
  alias Reports.Orders.Order
  alias Reports.Orders.Report

  @top_customer_count 5

  defmodule Order do
    @moduledoc "One order, parsed and validated from a CSV row."

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

  defmodule CustomerSummary do
    @moduledoc """
    What the report says about one customer.

    `completed_totals` maps each currency to the sum of that customer's
    completed orders in it. A customer without completed orders has an empty
    map. `last_placed_at` is when the customer's most recent order, of any
    status, was placed.
    """

    @enforce_keys [:customer_id, :completed_totals, :last_placed_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            customer_id: String.t(),
            completed_totals: %{String.t() => Decimal.t()},
            last_placed_at: DateTime.t()
          }
  end

  defmodule Report do
    @moduledoc """
    The report: a summary per customer and the customers with the most
    completed orders.

    `top_customers` lists up to five `{customer_id, completed_order_count}`
    pairs, most orders first; customers with the same count come in
    `customer_id` order.
    """

    @enforce_keys [:customers, :top_customers]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            customers: %{String.t() => CustomerSummary.t()},
            top_customers: [{String.t(), pos_integer()}]
          }
  end

  defmodule InvalidOrder do
    @moduledoc """
    The error reason when a row cannot be parsed into an order.

    `line` is the row's position in the input, counted from 1. `problem` is
    `:missing` when the field is absent and `:invalid` when it holds a value
    that cannot be parsed, in which case `value` is that value.
    """

    defexception [:line, :field, :problem, :value]

    @type t :: %__MODULE__{
            line: pos_integer() | nil,
            field: String.t(),
            problem: :missing | :invalid,
            value: term()
          }

    @impl true
    def message(%__MODULE__{problem: :missing} = error) do
      "row #{error.line}: missing field #{inspect(error.field)}"
    end

    def message(%__MODULE__{problem: :invalid} = error) do
      "row #{error.line}: invalid #{error.field}: #{inspect(error.value)}"
    end
  end

  @doc """
  Builds the report for `rows`.

  Returns `{:error, %Reports.Orders.InvalidOrder{}}` for the first row that
  cannot be parsed.
  """
  @spec build([map()]) :: {:ok, Report.t()} | {:error, InvalidOrder.t()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, report(orders)}
    end
  end

  @doc """
  Builds the report for `rows`, raising `Reports.Orders.InvalidOrder` for the
  first row that cannot be parsed.
  """
  @spec build!([map()]) :: Report.t()
  def build!(rows) do
    case build(rows) do
      {:ok, report} ->
        report

      {:error, error} ->
        raise error
    end
  end

  defp report(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize(customer_id, orders)} end)

    %Report{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize(customer_id, orders) do
    %CustomerSummary{
      customer_id: customer_id,
      completed_totals: completed_totals(orders),
      last_placed_at: last_placed_at(orders)
    }
  end

  defp completed_totals(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum(amounts)} end)
  end

  defp sum(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp last_placed_at(orders), do: Enum.max(Enum.map(orders, & &1.placed_at), DateTime)

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed?(order), do: order.status == :completed

  defp parse_orders(rows), do: parse_orders(Enum.with_index(rows, 1), [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([{row, line} | rows], orders) do
    case parse_order(row) do
      {:ok, order} ->
        parse_orders(rows, [order | orders])

      {:error, error} ->
        {:error, %InvalidOrder{error | line: line}}
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
      {:ok, value} -> {:error, invalid(key, value)}
      :error -> {:error, %InvalidOrder{field: key, problem: :missing}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {%Decimal{coef: coef} = amount, ""} when is_integer(coef) -> {:ok, amount}
      {_amount, _rest} -> {:error, invalid("amount", text)}
      :error -> {:error, invalid("amount", text)}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, invalid("placed_at", text)}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, invalid("status", other)}

  defp invalid(field, value), do: %InvalidOrder{field: field, problem: :invalid, value: value}
end
