defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer spending report from parsed CSV orders.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
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

  @doc """
  Builds the report for a list of string-keyed order maps.

  `:customers` maps each customer id to the total spent per currency across
  completed orders and the UTC date of their most recent order of any status.
  `:top_customers` lists up to five `{customer_id, completed_count}` pairs,
  most completed orders first, ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order
  that cannot be parsed, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-01-05T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-02-01T10:00:00Z",
      ...>     "status" => "pending"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2026-02-01]
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, parsed} ->
      case parse_order(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | parsed]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
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

  defp parse_order(_row), do: {:error, :invalid_payload}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
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
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_by_currency(orders),
      last_order_on: DateTime.to_date(latest.placed_at)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      total =
        currency_orders
        |> Enum.map(& &1.amount)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      {currency, total}
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} ->
      {-count, customer_id}
    end)
    |> Enum.take(@top_customer_count)
  end
end
