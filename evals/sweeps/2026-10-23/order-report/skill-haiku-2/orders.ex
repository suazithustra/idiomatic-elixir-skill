defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.
  """

  @top_count 5

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
          totals_by_currency: %{String.t() => Decimal.t()},
          last_order_on: Date.t(),
          completed_count: non_neg_integer()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report from parsed CSV rows.

  Totals and the top-customer ranking use completed orders only. The last
  order date uses every order, whatever its status. Top customers are ordered
  by completed-order count, highest first, with ties broken by customer id.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first row that does not parse.

  ## Examples

      iex> row = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "19.99",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2026-01-05T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> {:ok, report} = Reports.Orders.build([row])
      iex> report.customers["c1"].completed_count
      1
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_rows(rows) do
    parsed = Enum.map(rows, &parse_order/1)

    case Enum.find(parsed, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(parsed, fn {:ok, order} -> order end)}
      error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(text),
         {:ok, text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(text) do
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
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
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

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_text), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    top_customers =
      customers
      |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
      |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
      |> Enum.take(@top_count)

    %{customers: customers, top_customers: top_customers}
  end

  defp summarize_customer(customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == :completed))

    %{
      totals_by_currency: totals_by_currency(completed),
      last_order_on: last_order_on(customer_orders),
      completed_count: length(completed)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_on(customer_orders) do
    latest = Enum.max_by(customer_orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end
end
