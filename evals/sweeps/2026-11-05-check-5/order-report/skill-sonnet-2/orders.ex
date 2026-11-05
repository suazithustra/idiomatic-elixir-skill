defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with string keys: `"customer_id"`, `"amount"` (decimal
  string), `"currency"`, `"placed_at"` (ISO 8601 datetime) and `"status"`
  (`"completed"`, `"refunded"` or `"pending"`).

  Requires the `decimal` package.
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

  @type error ::
          {:invalid_order, non_neg_integer(),
           {:missing_field, String.t()}
           | {:invalid_field, String.t()}}

  @doc """
  Builds the report for a list of orders.

  For each customer the report holds the total spent per currency across
  completed orders, the number of completed orders, and the date of their most
  recent order (any status). `top_customers` lists up to five
  `{customer_id, completed_count}` pairs, most completed orders first, with
  ties broken by customer id. Customers without completed orders are left out
  of it.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order that
  is malformed, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "9.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-07T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.top_customers
      [{"c1", 2}]
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-07]
      iex> Decimal.to_string(report.customers["c1"].totals["EUR"])
      "25.00"
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = summarize_customers(orders)

      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, 0, [])

  defp parse_orders([], _index, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], index, orders) do
    case Order.parse(row) do
      {:ok, order} ->
        parse_orders(rest, index + 1, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_order, index, reason}}
    end
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
    last_order = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_order_on: DateTime.to_date(last_order.placed_at)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
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

defmodule Reports.Orders.Order do
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

  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, amount} <- parse_amount(row),
         {:ok, placed_at} <- parse_placed_at(row),
         {:ok, status} <- parse_status(row) do
      order = %__MODULE__{
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
      status_atom(text)
    end
  end

  defp status_atom("completed"), do: {:ok, :completed}
  defp status_atom("refunded"), do: {:ok, :refunded}
  defp status_atom("pending"), do: {:ok, :pending}
  defp status_atom(_other), do: {:error, {:invalid_field, "status"}}
end
