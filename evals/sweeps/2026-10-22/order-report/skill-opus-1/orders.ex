defmodule Reports.Orders.InvalidOrderError do
  @moduledoc """
  Returned by `Reports.Orders.build/1` when an order row is missing a field
  or has a value that cannot be parsed.

  `:index` is the zero-based position of the row in the input list.
  """

  @enforce_keys [:index, :field, :reason]
  defexception [:index, :field, :reason]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          field: String.t(),
          reason: :missing | :invalid
        }

  @impl true
  def message(%__MODULE__{reason: :missing} = error) do
    "order at index #{error.index} has no #{inspect(error.field)} field"
  end

  def message(%__MODULE__{reason: :invalid} = error) do
    "order at index #{error.index} has an invalid #{inspect(error.field)} field"
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

  @spec parse(map()) :: {:ok, t()} | {:error, {:missing | :invalid, String.t()}}
  def parse(row) when is_map(row) do
    with {:ok, customer_id} <- field(row, "customer_id", &parse_customer_id/1),
         {:ok, amount} <- field(row, "amount", &parse_amount/1),
         {:ok, currency} <- field(row, "currency", &parse_currency/1),
         {:ok, placed_at} <- field(row, "placed_at", &parse_placed_at/1),
         {:ok, status} <- field(row, "status", &parse_status/1) do
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

  defp field(row, key, parse) do
    case Map.fetch(row, key) do
      {:ok, text} when is_binary(text) -> parse_text(text, key, parse)
      {:ok, _other} -> {:error, {:invalid, key}}
      :error -> {:error, {:missing, key}}
    end
  end

  defp parse_text(text, key, parse) do
    case parse.(text) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid, key}}
    end
  end

  defp parse_customer_id(""), do: :error
  defp parse_customer_id(customer_id), do: {:ok, customer_id}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> check_amount(amount)
      {_amount, _rest} -> :error
      :error -> :error
    end
  end

  # Decimal.parse/1 accepts "NaN", "Infinity", and negative numbers,
  # none of which is a valid order amount.
  defp check_amount(amount) do
    if Decimal.nan?(amount) or Decimal.inf?(amount) or Decimal.negative?(amount) do
      :error
    else
      {:ok, amount}
    end
  end

  defp parse_currency(code) do
    if code =~ ~r/\A[A-Z]{3}\z/, do: {:ok, code}, else: :error
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: :error
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a sales report from order rows produced by a CSV parser.
  """

  alias Reports.Orders.{InvalidOrderError, Order}

  @top_customer_count 5

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          totals: %{currency() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{customer_id() => customer_summary()},
          top_customers: [{customer_id(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  Each row is a map with these string keys:

    * `"customer_id"` - a non-empty string.
    * `"amount"` - a non-negative decimal string, such as `"19.99"`.
    * `"currency"` - an ISO 4217 code, such as `"EUR"`.
    * `"placed_at"` - an ISO 8601 datetime with a UTC offset, such as
      `"2024-03-01T10:00:00Z"`.
    * `"status"` - `"completed"`, `"refunded"`, or `"pending"`.

  The report has two keys:

    * `:customers` - a map from customer ID to a summary with:
      * `:totals` - the sum of the amounts of the customer's completed
        orders, per currency. Empty if the customer has no completed orders.
      * `:last_order_on` - the UTC date of the customer's most recent order,
        whatever its status.
    * `:top_customers` - up to #{@top_customer_count} `{customer_id, completed_order_count}`
      tuples, most completed orders first. Customers with the same count
      are sorted by customer ID.

  Returns `{:error, %Reports.Orders.InvalidOrderError{}}` for the first row
  that is missing a field or has an invalid value.

  ## Examples

      iex> {:ok, report} =
      ...>   Reports.Orders.build([
      ...>     %{
      ...>       "customer_id" => "c1",
      ...>       "amount" => "19.99",
      ...>       "currency" => "EUR",
      ...>       "placed_at" => "2024-03-01T10:00:00Z",
      ...>       "status" => "completed"
      ...>     },
      ...>     %{
      ...>       "customer_id" => "c1",
      ...>       "amount" => "5.00",
      ...>       "currency" => "EUR",
      ...>       "placed_at" => "2024-03-05T09:30:00Z",
      ...>       "status" => "refunded"
      ...>     }
      ...>   ])
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("19.99")}
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> report.top_customers
      [{"c1", 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, %Reports.Orders.InvalidOrderError{index: 0, field: "amount", reason: :missing}}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, InvalidOrderError.t()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, report(orders)}
      {:error, %InvalidOrderError{}} = error -> error
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, 0, [])

  defp parse_orders([], _index, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rows], index, orders) do
    case Order.parse(row) do
      {:ok, order} ->
        parse_orders(rows, index + 1, [order | orders])

      {:error, {reason, field}} ->
        {:error, %InvalidOrderError{index: index, field: field, reason: reason}}
    end
  end

  defp report(orders) do
    %{
      customers: customer_summaries(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{
      totals: completed_totals(orders),
      last_order_on: last_order_on(orders)
    }
  end

  defp completed_totals(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum(amounts)} end)
  end

  defp sum(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  # Sorting on the customer ID as well keeps the order of tied customers
  # the same from one run to the next.
  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed?(%Order{status: status}), do: status == :completed
end
