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
  Builds a per-customer report from parsed CSV order rows.

  Each row is a string-keyed map with the keys `"customer_id"`, `"amount"`
  (a decimal string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime) and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  The report holds, for every customer, the total spent per currency across
  completed orders and the date of their most recent order of any status, plus
  the customers with the most completed orders.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-01-10T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.01",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-02-01T09:30:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %{spent: %{"EUR" => Decimal.new("19.99")}, last_order_date: ~D[2024-02-01]}
      iex> report.top_customers
      [{"c1", 1}]

  """

  alias Reports.Orders.Order

  @top_customer_count 5

  defstruct customers: %{}, top_customers: []

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          spent: %{currency() => Decimal.t()},
          last_order_date: Date.t()
        }

  @type t :: %__MODULE__{
          customers: %{customer_id() => customer_summary()},
          top_customers: [{customer_id(), pos_integer()}]
        }

  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}
  @type error :: {:invalid_row, pos_integer(), field_error()}

  @doc """
  Builds the report from a list of string-keyed order rows.

  Returns `{:error, {:invalid_row, row_number, reason}}` for the first row that
  lacks a field or holds one that does not parse. Row numbers start at 1.
  `top_customers` lists at most #{@top_customer_count} customers, ordered by
  completed order count and then by customer id.
  """
  @spec build([map()]) :: {:ok, t()} | {:error, error()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, 1, [])

  defp parse_orders([], _row_number, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], row_number, orders) do
    case parse_order(row) do
      {:ok, order} ->
        parse_orders(rest, row_number + 1, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_row, row_number, reason}}
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

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, ""} -> {:error, {:missing_field, key}}
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
    %__MODULE__{customers: customer_summaries(orders), top_customers: top_customers(orders)}
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{spent: spent_by_currency(orders), last_order_date: last_order_date(orders)}
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} -> {currency, total_amount(currency_orders)} end)
  end

  defp total_amount(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp last_order_date(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed?(order), do: order.status == :completed
end
