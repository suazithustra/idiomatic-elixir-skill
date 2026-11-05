defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from parsed CSV order rows.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Rows are parsed into
  `Reports.Orders.Order` structs first, so a malformed row is reported
  with the field that is wrong instead of producing a wrong total.
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
        {:ok, value} when is_binary(value) and value != "" ->
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

  @top_customer_count 5

  @typedoc "Summary of one customer's orders."
  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  Returns `{:error, reason}` for the first malformed row, where `reason` is
  `{:missing_field, key}`, `{:invalid_field, key}` or `{:unknown_status, status}`.

  For each customer the report holds:

    * `:totals` - the sum of `"amount"` over completed orders, per currency.
      A customer with no completed orders has no currencies.
    * `:completed_count` - the number of completed orders.
    * `:last_order_on` - the UTC date of the customer's most recent order of
      any status.

  `:top_customers` lists up to five `{customer_id, completed_count}` pairs,
  most completed orders first. Ties are ordered by customer id. Customers
  without a completed order are left out.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-01-10T09:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-02-01T09:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("15.00")
      iex> report.customers["c1"].last_order_on
      ~D[2024-02-01]
      iex> report.top_customers
      [{"c1", 2}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:missing_field, "amount"}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows, []) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], orders) do
    with {:ok, order} <- Order.parse(row) do
      parse_orders(rest, [order | orders])
    end
  end

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
      last_order_on: DateTime.to_date(last_order_at)
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
    |> Enum.reject(fn {_customer_id, count} -> count == 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
