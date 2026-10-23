defmodule Reports.Orders.Order do
  @moduledoc false

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

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed order rows.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (decimal
  string), `"currency"`, `"placed_at"` (ISO 8601 datetime) and `"status"`
  (`"completed"`, `"refunded"` or `"pending"`).
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  `:customers` maps each customer id to the total spent per currency across
  completed orders and the date of their most recent order. The most recent
  order counts whatever its status, so a customer with no completed orders
  still appears, with empty totals.

  `:top_customers` lists up to five `{customer_id, completed_orders}` pairs,
  most completed orders first. Ties are broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, where `index` is its position in the list.

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
      ...>     "placed_at" => "2026-03-05T10:00:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].last_order_on
      ~D[2026-03-05]
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) ::
          {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    last_order_on =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)
      |> DateTime.to_date()

    %{totals: totals_per_currency(orders), last_order_on: last_order_on}
  end

  defp totals_per_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    # Negated count sorts the highest first while the id breaks ties ascending.
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &accumulate_order/2)
    |> reverse_orders()
  end

  defp accumulate_order({row, index}, {:ok, parsed}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | parsed]}}
      {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
    end
  end

  defp reverse_orders({:ok, orders}), do: {:ok, Enum.reverse(orders)}
  defp reverse_orders({:error, _reason} = error), do: error

  defp parse_order(row) do
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
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
