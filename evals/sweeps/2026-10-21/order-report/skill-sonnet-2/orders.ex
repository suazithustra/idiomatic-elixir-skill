defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows as produced by a CSV parser.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

  defmodule Order do
    @moduledoc false
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

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @top_customer_count 5

  @doc """
  Builds the report, or returns the first error found in the input rows.

  For each customer, `:totals` sums the amounts of completed orders per
  currency, `:completed_count` counts them, and `:last_order_on` is the date of
  the customer's most recent order of any status. `:top_customers` lists up to
  five `{customer_id, completed_count}` pairs, most completed orders first,
  ties broken by customer id.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T09:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers =
        orders
        |> Enum.group_by(& &1.customer_id)
        |> Map.new(fn {customer_id, orders} -> {customer_id, summarize(orders)} end)

      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- fetch_field(row, "customer_id"),
         {:ok, amount} <- fetch_amount(row),
         {:ok, currency} <- fetch_field(row, "currency"),
         {:ok, placed_at} <- fetch_placed_at(row),
         {:ok, status} <- fetch_status(row) do
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

  defp fetch_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_amount(row) do
    with {:ok, amount} <- fetch_field(row, "amount") do
      case Decimal.parse(amount) do
        {decimal, ""} -> {:ok, decimal}
        _invalid -> {:error, {:invalid_field, "amount"}}
      end
    end
  end

  defp fetch_placed_at(row) do
    with {:ok, placed_at} <- fetch_field(row, "placed_at") do
      case DateTime.from_iso8601(placed_at) do
        {:ok, datetime, _utc_offset} -> {:ok, datetime}
        {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
      end
    end
  end

  defp fetch_status(row) do
    with {:ok, status} <- fetch_field(row, "status") do
      parse_status(status)
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    last_order_on =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)
      |> DateTime.to_date()

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_on: last_order_on
    }
  end

  defp totals_by_currency(completed) do
    Enum.reduce(completed, %{}, fn order, totals ->
      Map.update(totals, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
