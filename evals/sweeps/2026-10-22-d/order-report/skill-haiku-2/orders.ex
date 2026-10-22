defmodule Reports.Orders do
  @moduledoc """
  Builds per-customer reports from order rows produced by a CSV parser.
  """

  @top_count 5

  defmodule Order do
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

  @type summary :: %{
          customer_id: String.t(),
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{customers: [summary()], top_customers: [summary()]}

  @doc """
  Builds the report from rows with string keys.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that does
  not parse. The report is a map with two keys:

    * `:customers` - a summary for every customer, sorted by `customer_id`
    * `:top_customers` - up to five customers with the most completed orders,
      most first; ties are ordered by `customer_id`

  Each summary has `:customer_id`, `:totals` (the amounts of completed orders
  keyed by currency, as `Decimal`), `:completed_count`, and `:last_order_on`,
  the UTC date of the customer's most recent order of any status.

  ## Examples

      iex> Reports.Orders.build([%{"customer_id" => "c1", "amount" => "x"}])
      {:error, {:invalid_field, "amount"}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, build_report(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, &collect_order/2)
  end

  defp collect_order(row, {:ok, parsed}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | parsed]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp parse_order(row) do
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
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp build_report(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Enum.map(fn {customer_id, customer_orders} ->
        summarize(customer_id, customer_orders)
      end)
      |> Enum.sort_by(& &1.customer_id)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize(customer_id, orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customer_id: customer_id,
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} -> {currency, sum_amounts(currency_orders)} end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(&(&1.completed_count > 0))
    |> Enum.sort_by(&{-&1.completed_count, &1.customer_id})
    |> Enum.take(@top_count)
  end
end
