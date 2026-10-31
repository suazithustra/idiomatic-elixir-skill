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
  Builds a customer report from order rows as a CSV parser produces them.

  Each row is a map with the string keys `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`. Rows are parsed into `Reports.Orders.Order` structs
  before anything is summed, so a malformed row is reported instead of skewing a total.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  Per customer, `totals` holds the amount spent in each currency across completed
  orders, `completed_count` the number of completed orders, and `last_order_on` the
  date of the most recent order of any status. `top_customers` lists up to five
  `{customer_id, completed_count}` pairs, most completed orders first, ties broken by
  customer id. Customers with no completed orders are left out of it.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}` for the
  first row that cannot be parsed.

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
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-04T09:30:00Z",
      ...>     "status" => "pending"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].last_order_on
      ~D[2026-03-04]
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = summarize_customers(orders)

      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rest, [order | orders])
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parse_amount(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parse_placed_at(row),
         {:ok, status} <- parse_status(row) do
      {:ok,
       %Order{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(row) do
    with {:ok, text} <- string_field(row, "amount") do
      case Decimal.parse(text) do
        {amount, ""} ->
          {:ok, amount}

        {_amount, _rest} ->
          {:error, {:invalid_field, "amount"}}

        :error ->
          {:error, {:invalid_field, "amount"}}
      end
    end
  end

  defp parse_placed_at(row) do
    with {:ok, text} <- string_field(row, "placed_at") do
      case DateTime.from_iso8601(text) do
        {:ok, placed_at, _utc_offset} ->
          {:ok, placed_at}

        {:error, _reason} ->
          {:error, {:invalid_field, "placed_at"}}
      end
    end
  end

  defp parse_status(row) do
    with {:ok, text} <- string_field(row, "status") do
      status_from_string(text)
    end
  end

  defp status_from_string("completed"), do: {:ok, :completed}
  defp status_from_string("refunded"), do: {:ok, :refunded}
  defp status_from_string("pending"), do: {:ok, :pending}
  defp status_from_string(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(customers) do
    customers
    |> Enum.reject(fn {_customer_id, summary} -> summary.completed_count == 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_count, customer_id} end)
    |> Enum.take(@top_customer_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
  end
end
