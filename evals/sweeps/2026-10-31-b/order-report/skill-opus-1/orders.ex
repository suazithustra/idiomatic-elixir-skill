defmodule Reports.Orders do
  @moduledoc """
  Builds a report from the order rows of a CSV file.

  Rows are maps with the string keys `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`. They are parsed before anything is computed, so a bad
  row fails the whole report instead of silently changing its totals.
  """

  defmodule InvalidOrderError do
    @moduledoc """
    The error `Reports.Orders.build/1` returns for a row it cannot parse.

    `:row` is the row's 1-based position in the list, and `:reason` is
    `{:missing_field, key}` or `{:invalid_field, key}`.
    """

    defexception [:row, :reason]

    @type t :: %__MODULE__{
            row: pos_integer(),
            reason: {:missing_field, String.t()} | {:invalid_field, String.t()}
          }

    @impl true
    def message(%__MODULE__{reason: {:missing_field, key}} = error) do
      "row #{error.row}: missing field #{inspect(key)}"
    end

    def message(%__MODULE__{reason: {:invalid_field, key}} = error) do
      "row #{error.row}: invalid field #{inspect(key)}"
    end
  end

  defmodule Order do
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
  end

  @type customer_summary :: %{
          total_spent: %{String.t() => Decimal.t()},
          last_order_date: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customers_limit 5

  @doc """
  Builds the report for `rows`.

  The report holds:

    * `:customers` - a map from customer ID to the customer's summary. Its `:total_spent`
      maps each currency to the sum of the customer's completed orders, and is empty for
      a customer with none. Its `:last_order_date` is the UTC date of the customer's most
      recent order of any status.
    * `:top_customers` - up to five `{customer_id, completed_order_count}` tuples, most
      completed orders first. Ties go to the lower customer ID, so the result does not
      depend on row order.

  Returns `{:error, %InvalidOrderError{}}` for the first row that has a missing or blank
  field, an amount that is not a finite decimal, an unknown status, or a `"placed_at"`
  without a UTC offset, whose date and place among other orders cannot be known.

  ## Examples

      iex> completed = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "19.99",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2024-03-01T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> pending = %{completed | "status" => "pending", "placed_at" => "2024-03-05T09:30:00Z"}
      iex> {:ok, report} = Reports.Orders.build([completed, pending])
      iex> report.customers
      %{"c1" => %{total_spent: %{"EUR" => Decimal.new("19.99")}, last_order_date: ~D[2024-03-05]}}
      iex> report.top_customers
      [{"c1", 1}]

      iex> {:error, error} = Reports.Orders.build([%{"customer_id" => "c1"}])
      iex> Exception.message(error)
      ~s(row 1: missing field "amount")

  """
  @spec build([map()]) :: {:ok, report()} | {:error, InvalidOrderError.t()}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &parse_row/2)
  end

  defp parse_row({row, row_number}, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} ->
        {:cont, {:ok, [order | orders]}}

      {:error, reason} ->
        {:halt, {:error, %InvalidOrderError{row: row_number, reason: reason}}}
    end
  end

  defp parse_order(%{} = row) do
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
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
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

  # Decimal.parse/1 accepts "NaN" and "Infinity", and either would poison a total.
  defp finite_amount(amount) do
    if Decimal.nan?(amount) or Decimal.inf?(amount) do
      {:error, {:invalid_field, "amount"}}
    else
      {:ok, amount}
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

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)
  end

  defp summarize_customer(orders) do
    %{total_spent: total_spent(orders), last_order_date: last_order_date(orders)}
  end

  defp total_spent(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum(amounts)} end)
  end

  defp sum(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp last_order_date(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers_limit)
  end

  defp completed?(order), do: order.status == :completed
end
