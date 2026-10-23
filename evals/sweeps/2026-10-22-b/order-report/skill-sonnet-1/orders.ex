defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer spending report from parsed CSV order rows.

  Rows are string-keyed maps with `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`. They are validated and converted to
  `Reports.Orders.Order` structs before any aggregation happens.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  For each customer the report holds the total spent per currency across
  completed orders (`:totals`) and the date of their most recent order of any
  status (`:last_order_on`). `:top_customers` lists up to five
  `{customer_id, completed_order_count}` pairs, most completed orders first,
  with ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  fails validation, where `index` is its zero-based position.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T08:30:00Z",
      ...>     "status" => "pending"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("19.99")
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, t()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case Order.parse(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    by_customer = Enum.group_by(orders, & &1.customer_id)

    %{
      customers: Map.new(by_customer, fn {id, orders} -> {id, summarize_customer(orders)} end),
      top_customers: top_customers(by_customer)
    }
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_by_currency(orders),
      last_order_on: DateTime.to_date(latest.placed_at)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} ->
      {currency, Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(by_customer) do
    by_customer
    |> Enum.map(fn {id, orders} -> {id, Enum.count(orders, &(&1.status == :completed))} end)
    |> Enum.reject(fn {_id, completed} -> completed == 0 end)
    |> Enum.sort_by(fn {id, completed} -> {-completed, id} end)
    |> Enum.take(@top_customer_count)
  end
end

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

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      {:ok,
       %__MODULE__{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp string_field(row, key) do
    case row do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
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
