defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from parsed CSV order rows.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Rows are validated and turned
  into structs before anything is computed, so one bad row fails the whole
  report instead of skewing it.
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
  Builds the report for a list of order rows.

  The report has two parts:

    * `:customers` - for each customer id, `:totals` (the sum of completed
      order amounts per currency) and `:last_order_on` (the UTC date of their
      latest order of any status).
    * `:top_customers` - up to five `{customer_id, completed_count}` pairs,
      most completed orders first, ties broken by customer id.

  A customer with no completed orders has empty `:totals`.

  Returns `{:error, {:invalid_field, name}}` or `{:error, :invalid_order}` for
  the first row that cannot be parsed.

  ## Examples

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, :invalid_order}

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, &collect_order/2)
  end

  defp collect_order(row, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_placed_at(placed_at),
         {:ok, status} <- parse_status(status) do
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

  defp parse_order(_row), do: {:error, :invalid_order}

  defp parse_amount(text) when is_binary(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_text), do: {:error, {:invalid_field, "amount"}}

  defp parse_placed_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_at(_text), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    totals =
      orders
      |> Enum.filter(&completed?/1)
      |> Enum.group_by(& &1.currency, & &1.amount)
      |> Map.new(fn {currency, amounts} -> {currency, sum(amounts)} end)

    %{totals: totals, last_order_on: DateTime.to_date(latest.placed_at)}
  end

  defp sum(amounts) do
    Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed?(%Order{status: status}), do: status == :completed
end
