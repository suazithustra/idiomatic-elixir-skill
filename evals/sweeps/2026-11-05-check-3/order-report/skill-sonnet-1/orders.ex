defmodule Reports.Orders do
  @moduledoc """
  Builds a report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Orders are parsed into
  `Reports.Orders.Order` structs first, so a bad row is reported before any
  figure is computed.
  """

  defmodule Order do
    @moduledoc false

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
  end

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type error ::
          {:invalid_order, index :: non_neg_integer(), reason :: term()}

  @top_customer_count 5

  @doc """
  Builds the report for a list of orders.

  For each customer the report holds `:totals`, the sum of completed orders per
  currency, and `:last_order_on`, the date of their most recent order of any
  status. `:top_customers` lists up to #{@top_customer_count} `{customer_id, count}`
  pairs, ordered by number of completed orders, highest first. Ties are broken
  by customer id.

  A customer with no completed orders has empty `:totals` and is not ranked.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order that
  cannot be parsed, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.01",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T08:30:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> Decimal.to_string(report.customers["c1"].totals["EUR"])
      "25.00"
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok,
       %{
         customers: customer_summaries(orders),
         top_customers: top_customers(orders)
       }}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | orders]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
    |> case do
      {:ok, orders} ->
        {:ok, Enum.reverse(orders)}

      {:error, _reason} = error ->
        error
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

  defp parse_order(_row), do: {:error, :not_a_map}

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

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(orders) do
    last_order = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_per_currency(orders),
      last_order_on: DateTime.to_date(last_order.placed_at)
    }
  end

  defp totals_per_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
