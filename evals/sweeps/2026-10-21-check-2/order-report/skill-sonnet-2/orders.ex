defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed CSV order rows.

  Rows are string-keyed maps with `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`. They are parsed into `Reports.Orders.Order`
  structs first, so a malformed row is reported as an error instead of
  producing wrong totals.
  """

  defmodule Order do
    @moduledoc false

    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct [:customer_id, :amount, :currency, :placed_at, :status]

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
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customer_count 5

  @doc """
  Builds the report from a list of order rows.

  The report has:

    * `:customers` - for each customer id, `:totals` (the sum of completed
      order amounts per currency) and `:last_order_on` (the UTC date of the
      customer's most recent order, whatever its status). A customer with no
      completed orders has empty `:totals`.
    * `:top_customers` - up to 5 `{customer_id, completed_order_count}` tuples,
      most orders first. Ties are broken by customer id.

  Returns `{:error, reason}` for the first invalid row, for example
  `{:missing_field, "amount"}` or `{:invalid_field, "status"}`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "7.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-09T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("25.00")
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-09]
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, t()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end)
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
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
      _other -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
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
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{totals: totals_per_currency(orders), last_order_on: last_order_on(orders)}
  end

  defp totals_per_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
