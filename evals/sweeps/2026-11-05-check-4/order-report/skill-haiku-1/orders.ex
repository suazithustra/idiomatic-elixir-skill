defmodule Reports.Orders.Error do
  @moduledoc """
  Reason returned by `Reports.Orders.build/1` when an order row cannot be read.

  `:field` names the part of the row that failed (`:amount`, `:placed_at`,
  `:status`), or `:row` when a required key is missing. `:value` holds the
  rejected input, when there is one.
  """

  defexception [:field, :value]

  @type t :: %__MODULE__{field: :amount | :placed_at | :status | :row | nil, value: term()}

  @impl true
  def message(%{field: :row}), do: "order row is missing a required key"

  def message(%{field: field, value: value}) do
    "invalid #{field}: #{inspect(value)}"
  end
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"` (such as `"EUR"`), `"placed_at"`
  (an ISO 8601 datetime) and `"status"` (`"completed"`, `"refunded"` or
  `"pending"`).
  """

  alias Reports.Orders.Error

  @top_count 5

  @typedoc "Per-customer totals and dates."
  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_at: DateTime.t()
        }

  @typedoc "The report returned by `build/1`."
  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report for a list of order rows.

  The report is a map with two keys:

    * `:customers` - a map from `customer_id` to a map with:
      * `:spent` - a map from currency to the `Decimal` total of the
        customer's completed orders in that currency
      * `:completed_count` - the number of completed orders
      * `:last_order_at` - the latest `DateTime` among all of the customer's
        orders, whatever their status
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first, ties broken by `customer_id`. Customers
      with no completed orders are left out.

  Returns `{:error, %Reports.Orders.Error{}}` for the first row whose amount,
  timestamp or status cannot be read, or that lacks a required key.

  ## Examples

      iex> {:ok, report} = Reports.Orders.build([])
      iex> report
      %{customers: %{}, top_customers: []}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, Error.t()}
  def build(orders) do
    with {:ok, rows} <- parse_rows(orders) do
      customers = summarize(rows)
      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_rows(orders) do
    rows = Enum.map(orders, &parse_row/1)

    case Enum.find(rows, &match?({:error, _error}, &1)) do
      nil -> {:ok, Enum.map(rows, fn {:ok, row} -> row end)}
      error -> error
    end
  end

  defp parse_row(%{
         "customer_id" => customer_id,
         "amount" => amount_text,
         "currency" => currency,
         "placed_at" => placed_at_text,
         "status" => status_text
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status} <- parse_status(status_text) do
      row = %{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_at: placed_at,
        status: status
      }

      {:ok, row}
    end
  end

  defp parse_row(_row), do: {:error, %Error{field: :row}}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, %Error{field: :amount, value: text}}
      :error -> {:error, %Error{field: :amount, value: text}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, %Error{field: :placed_at, value: text}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, %Error{field: :status, value: other}}

  defp summarize(rows) do
    groups = Enum.group_by(rows, & &1.customer_id)

    Map.new(groups, fn {customer_id, customer_rows} ->
      {customer_id, summarize_customer(customer_rows)}
    end)
  end

  defp summarize_customer(rows) do
    completed = Enum.filter(rows, &(&1.status == :completed))

    last_order_at =
      rows
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{
      spent: spent_by_currency(completed),
      completed_count: length(completed),
      last_order_at: last_order_at
    }
  end

  defp spent_by_currency(completed) do
    amounts_by_currency = Enum.group_by(completed, & &1.currency, & &1.amount)

    Map.new(amounts_by_currency, fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_count > 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_count, customer_id} end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
  end
end
