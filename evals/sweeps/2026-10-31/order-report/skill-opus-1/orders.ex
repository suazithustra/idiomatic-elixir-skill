defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from the order rows of a CSV file.
  """

  alias Reports.Orders.Order

  @top_customers_limit 5

  @type customer_summary :: %{
          total_spent: %{String.t() => Decimal.t()},
          most_recent_order_on: Date.t()
        }

  @type top_customer :: %{customer_id: String.t(), completed_orders: pos_integer()}

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [top_customer()]
        }

  @type error :: {:invalid_order, pos_integer(), Order.field_error()}

  @doc """
  Builds the report from `rows`, the maps the CSV parser produces.

  Each row needs the string keys `"customer_id"`, `"amount"`, `"currency"`, `"placed_at"` and
  `"status"`, all holding strings. `"placed_at"` must include a UTC offset, because without one
  the moment of the order is unknown.

  The report has two keys:

    * `:customers` - a map from customer ID to that customer's summary. `:total_spent` sums the
      completed orders per currency and is empty for a customer with none.
      `:most_recent_order_on` is the UTC date of the customer's latest order of any status.
    * `:top_customers` - the #{@top_customers_limit} customers with the most completed orders,
      highest count first, with ties in customer ID order.

  One invalid row fails the whole report, because totals that skip an order would be wrong
  without showing it. The error holds the row's position in `rows`, counting from 1, and the
  field that failed.

  ## Examples

      iex> completed = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "19.99",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2024-03-01T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> pending = %{completed | "status" => "pending", "placed_at" => "2024-03-05T10:00:00Z"}
      iex> {:ok, report} = Reports.Orders.build([completed, pending])
      iex> report.customers["c1"].total_spent
      %{"EUR" => Decimal.new("19.99")}
      iex> report.customers["c1"].most_recent_order_on
      ~D[2024-03-05]
      iex> report.top_customers
      [%{customer_id: "c1", completed_orders: 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_order, 1, {:missing_field, "amount"}}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: customer_summaries(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, 1, [])

  defp parse_orders([], _position, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], position, orders) do
    case Order.parse(row) do
      {:ok, order} ->
        parse_orders(rest, position + 1, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_order, position, reason}}
    end
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, orders} -> {customer_id, customer_summary(orders)} end)
  end

  defp customer_summary(orders) do
    %{total_spent: total_spent(orders), most_recent_order_on: most_recent_order_on(orders)}
  end

  defp total_spent(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp most_recent_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_customers_limit)
    |> Enum.map(fn {id, count} -> %{customer_id: id, completed_orders: count} end)
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

  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}

  @spec parse(map()) :: {:ok, t()} | {:error, field_error()}
  def parse(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency_text} <- string_field(row, "currency"),
         {:ok, currency} <- parse_currency(currency_text),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
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
    case row do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        finite_amount(amount)

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  # Decimal.parse/1 accepts "NaN" and "Infinity", and either would swallow a customer's whole total.
  defp finite_amount(amount) do
    if Decimal.nan?(amount) or Decimal.inf?(amount) do
      {:error, {:invalid_field, "amount"}}
    else
      {:ok, amount}
    end
  end

  # Totals are keyed by this string, so "eur" must not become a second bucket beside "EUR".
  defp parse_currency(text) do
    if text =~ ~r/\A[A-Z]{3}\z/ do
      {:ok, text}
    else
      {:error, {:invalid_field, "currency"}}
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
end
