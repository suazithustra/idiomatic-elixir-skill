defmodule Reports.Orders do
  @moduledoc """
  Builds per-customer order reports from rows produced by a CSV parser.
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

  @doc """
  Builds a report from CSV rows.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime), and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).

  The report has two keys:

    * `:customers` - maps each customer id to a map with `:totals`, the
      completed amounts per currency as `Decimal`s, `:completed_count`, the
      number of completed orders, and `:last_order_at`, the latest `DateTime`
      across all of the customer's orders in any status.
    * `:top_customers` - up to five `{customer_id, completed_count}` pairs,
      most completed orders first. Ties are ordered by customer id.

  Returns `{:error, reason}` for the first row that does not parse.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:missing_field, "amount"}}
  """
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
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_text),
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
      {:ok, value} when is_binary(value) -> {:ok, value}
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
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    last_order_at =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_at: last_order_at
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp top_customers(customers) do
    customers
    |> Enum.sort_by(fn {customer_id, summary} ->
      {-summary.completed_count, customer_id}
    end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
  end
end
