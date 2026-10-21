defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from orders parsed out of a CSV file.
  """

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

  @top_customer_count 5

  @type row :: %{optional(String.t()) => String.t()}

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}

  @type error_reason :: {:invalid_order, non_neg_integer(), field_error()}

  @doc """
  Builds a report from a list of order rows with string keys.

  Each row needs `"customer_id"`, `"amount"` (a non-negative decimal string
  such as `"19.99"`), `"currency"` (a three-letter code such as `"EUR"`),
  `"placed_at"` (an ISO 8601 datetime with an offset) and `"status"`
  (`"completed"`, `"refunded"` or `"pending"`).

  The report has two keys:

    * `:customers` - a map from customer ID to a summary with `:totals`, the
      sum of completed order amounts per currency as `Decimal`s, and
      `:last_order_at`, the UTC datetime of the customer's most recent order
      of any status.
    * `:top_customers` - up to #{@top_customer_count} `{customer_id, count}`
      tuples for the customers with the most completed orders, most first.
      Ties are ordered by customer ID.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, where `index` is the row's zero-based position in the list
  and `reason` is `{:missing_field, key}` or `{:invalid_field, key}`.

  ## Examples

      iex> {:ok, report} =
      ...>   Reports.Orders.build([
      ...>     %{
      ...>       "customer_id" => "c1",
      ...>       "amount" => "19.99",
      ...>       "currency" => "EUR",
      ...>       "placed_at" => "2024-05-01T10:00:00Z",
      ...>       "status" => "completed"
      ...>     },
      ...>     %{
      ...>       "customer_id" => "c1",
      ...>       "amount" => "5.00",
      ...>       "currency" => "EUR",
      ...>       "placed_at" => "2024-05-03T09:30:00+02:00",
      ...>       "status" => "pending"
      ...>     }
      ...>   ])
      iex> report.customers["c1"].last_order_at
      ~U[2024-05-03 07:30:00Z]
      iex> report.top_customers
      [{"c1", 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1", "amount" => "19.99"}])
      {:error, {:invalid_order, 0, {:missing_field, "currency"}}}

  """
  @spec build([row()]) :: {:ok, report()} | {:error, error_reason()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows, 0, []) do
      {:ok, orders} -> {:ok, report(orders)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp report(orders) do
    %{customers: summarize_customers(orders), top_customers: top_customers(orders)}
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{
      totals: completed_totals(orders),
      last_order_at: Enum.max_by(orders, & &1.placed_at, DateTime).placed_at
    }
  end

  defp completed_totals(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed?(%Order{status: status}), do: status == :completed

  defp parse_orders([], _index, orders), do: {:ok, orders}

  defp parse_orders([row | rows], index, orders) do
    case parse_order(row) do
      {:ok, order} -> parse_orders(rows, index + 1, [order | orders])
      {:error, reason} -> {:error, {:invalid_order, index, reason}}
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- fetch_field(row, "customer_id", &parse_customer_id/1),
         {:ok, amount} <- fetch_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- fetch_field(row, "currency", &parse_currency/1),
         {:ok, placed_at} <- fetch_field(row, "placed_at", &parse_placed_at/1),
         {:ok, status} <- fetch_field(row, "status", &parse_status/1) do
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

  defp fetch_field(row, key, parse) do
    case Map.fetch(row, key) do
      {:ok, value} -> tag_invalid(parse.(value), key)
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp tag_invalid({:ok, value}, _key), do: {:ok, value}
  defp tag_invalid(:error, key), do: {:error, {:invalid_field, key}}

  defp parse_customer_id(""), do: :error
  defp parse_customer_id(customer_id) when is_binary(customer_id), do: {:ok, customer_id}

  # A regex rather than Decimal.parse/1, which also accepts "NaN" and "Inf".
  defp parse_amount(amount) when is_binary(amount) do
    if amount =~ ~r/\A\d+(\.\d+)?\z/, do: {:ok, Decimal.new(amount)}, else: :error
  end

  defp parse_currency(currency) when is_binary(currency) do
    if currency =~ ~r/\A[A-Z]{3}\z/, do: {:ok, currency}, else: :error
  end

  defp parse_placed_at(placed_at) when is_binary(placed_at) do
    case DateTime.from_iso8601(placed_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_status), do: :error
end
