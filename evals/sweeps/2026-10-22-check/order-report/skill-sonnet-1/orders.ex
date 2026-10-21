defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed CSV order rows.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct [:customer_id, :amount, :currency, :placed_at, :status]

    @type t :: %__MODULE__{
            customer_id: String.t(),
            amount: Decimal.t(),
            currency: String.t(),
            placed_at: DateTime.t(),
            status: :completed | :refunded | :pending
          }
  end

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customer_count 5

  @doc """
  Builds the report from a list of order rows.

  For each customer, `:totals` holds the amount spent per currency across
  completed orders, and `:last_order_on` is the date of their most recent
  order of any status. `:top_customers` lists up to five
  `{customer_id, completed_order_count}` pairs, highest count first, with ties
  broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  is malformed, where `index` is its position in the list.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T09:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("10.50")
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) ::
          {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    %{
      customers: summarize_customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{totals: totals_by_currency(orders), last_order_on: last_order_on(orders)}
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp last_order_on(orders) do
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
    |> Enum.take(@top_customer_count)
  end

  defp completed?(%Order{status: status}), do: status == :completed

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, parsed} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | parsed]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
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
      {%Decimal{coef: coef} = amount, ""} when is_integer(coef) -> {:ok, amount}
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
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
