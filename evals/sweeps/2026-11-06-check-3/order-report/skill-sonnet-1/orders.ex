defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report and a top-customers ranking from CSV order rows.

  Rows are string-keyed maps with `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`. Dates are taken in UTC.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  For each customer, `:totals` holds the amount spent per currency across
  completed orders, and `:last_order_on` the date of their most recent order
  of any status. `:top_customers` lists up to five `{customer_id, completed_count}`
  pairs, most completed orders first, ties broken by customer id.

  Returns `{:error, reason}` for the first row that cannot be parsed.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.top_customers
      [{"c1", 1}]
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-01]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows, []) do
      {:ok, %{customers: customer_reports(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders([], orders), do: {:ok, orders}

  defp parse_orders([row | rest], orders) do
    with {:ok, order} <- Order.parse(row) do
      parse_orders(rest, [order | orders])
    end
  end

  defp customer_reports(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, orders} -> {customer_id, customer_report(orders)} end)
  end

  defp customer_report(orders) do
    %{totals: totals_by_currency(orders), last_order_on: last_order_on(orders)}
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&Order.completed?/1)
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} -> {currency, sum_amounts(orders)} end)
  end

  defp sum_amounts(orders), do: Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))

  defp last_order_on(orders), do: Enum.max(Enum.map(orders, & &1.placed_on), Date)

  defp top_customers(orders) do
    orders
    |> Enum.filter(&Order.completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end

defmodule Reports.Orders.Order do
  @moduledoc false

  @enforce_keys [:customer_id, :amount, :currency, :placed_on, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_on: Date.t(),
          status: :completed | :refunded | :pending
        }

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(
        %{
          "customer_id" => customer_id,
          "amount" => amount,
          "currency" => currency,
          "placed_at" => placed_at,
          "status" => status
        } = row
      ) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_on} <- parse_placed_on(placed_at),
         {:ok, status} <- parse_status(status) do
      {:ok,
       %__MODULE__{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_on: placed_on,
         status: status
       }}
    else
      {:error, reason} -> {:error, {reason, row}}
    end
  end

  def parse(row), do: {:error, {:invalid_order, row}}

  @spec completed?(t()) :: boolean()
  def completed?(%__MODULE__{status: :completed}), do: true
  def completed?(%__MODULE__{}), do: false

  defp parse_amount(text) when is_binary(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      _invalid -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_other), do: {:error, {:invalid_field, "amount"}}

  defp parse_placed_on(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_on(_other), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}
end
