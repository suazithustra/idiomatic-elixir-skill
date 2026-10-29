defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Only `completed` orders count toward spending and order totals. The
  last order date considers orders of every status.
  """

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

  @top_count 5

  @doc """
  Builds the report from order rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first row that
  cannot be read. `report.customers` maps each customer ID to:

    * `:spent` - completed totals as `%{currency => Decimal.t()}`
    * `:completed_count` - number of completed orders
    * `:last_order_at` - `DateTime` of the most recent order of any status

  `report.top_customers` lists up to five `{customer_id, completed_count}`
  tuples, most completed orders first. Ties are ordered by customer ID.

  ## Examples

      iex> row = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "10.00",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2026-01-02T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> {:ok, report} = Reports.Orders.build([row])
      iex> report.top_customers
      [{"c1", 1}]

  """
  @spec build([map()]) ::
          {:ok, %{customers: map(), top_customers: [{String.t(), non_neg_integer()}]}}
          | {:error, term()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
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
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- amount_field(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- placed_at_field(row),
         {:ok, status} <- status_field(row) do
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
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp amount_field(row) do
    with {:ok, text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(text) do
      {:ok, amount}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      _ -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp placed_at_field(row) do
    with {:ok, text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(text) do
      {:ok, placed_at}
    end
  end

  # Requires an offset such as "Z" or "+02:00"; without one, parsing fails.
  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp status_field(row) do
    with {:ok, text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(text) do
      {:ok, status}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    customers = summarize_customers(orders)
    %{customers: customers, top_customers: top_customers(customers)}
  end

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
      spent: spent_by_currency(completed),
      completed_count: length(completed),
      last_order_at: last_order_at(orders)
    }
  end

  defp spent_by_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, customer} -> {customer_id, customer.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
