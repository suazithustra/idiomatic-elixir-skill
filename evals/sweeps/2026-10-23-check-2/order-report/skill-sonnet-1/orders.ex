defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed CSV order rows.

  Rows are string-keyed maps with `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`. They are parsed into `Reports.Orders.Order`
  structs first, so a malformed row is reported as an error instead of
  producing wrong totals.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  defmodule Order do
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
          :invalid_order
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Builds the report from a list of string-keyed order maps.

  For each customer the report holds the total spent per currency across
  completed orders, the number of completed orders, and the date (UTC) of the
  most recent order of any status. `top_customers` lists up to five
  `{customer_id, completed_count}` pairs, most completed orders first, with
  ties broken by customer id. Customers without a completed order are left out
  of it.

  Returns the first row error as `{:error, {index, reason}}`, where `index` is
  the position of the row in the list.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-01-05T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.top_customers
      [{"c1", 1}]
      iex> report.customers["c1"].last_order_on
      ~D[2026-01-05]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {non_neg_integer(), error()}}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &parse_indexed_order/2)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_indexed_order({row, index}, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, reason} -> {:halt, {:error, {index, reason}}}
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

  defp parse_order(_row), do: {:error, :invalid_order}

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
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    last_order =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_on: DateTime.to_date(last_order)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} ->
      {currency, Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
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
