defmodule Reports.Orders do
  @moduledoc """
  Builds a report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Orders are validated and
  converted to `Reports.Orders.Order` structs before any totals are computed.
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
  Builds the report for a list of order maps.

  The report holds two keys:

    * `:customers` - for each customer id, `:totals` (the sum of completed
      orders per currency) and `:last_order_on` (the date of the most recent
      order of any status). A customer with no completed orders has empty
      `:totals`.
    * `:top_customers` - up to five `{customer_id, completed_orders}` pairs,
      most completed orders first, ties broken by customer id.

  Returns `{:error, reason}` for the first order that is missing a field or
  holds an invalid value.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.top_customers
      [{"c1", 1}]
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-01]
      iex> Decimal.to_string(report.customers["c1"].totals["EUR"])
      "19.99"

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:missing_field, "amount"}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(rows, parsed \\ [])

  defp parse_orders([], parsed), do: {:ok, parsed}

  defp parse_orders([row | rest], parsed) do
    with {:ok, order} <- Order.parse(row) do
      parse_orders(rest, [order | parsed])
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
    last_placed_at = Enum.max_by(orders, & &1.placed_at, DateTime).placed_at

    %{
      totals: totals_per_currency(Enum.filter(orders, &completed?/1)),
      last_order_on: DateTime.to_date(last_placed_at)
    }
  end

  defp totals_per_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
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
end
