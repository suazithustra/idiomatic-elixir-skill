defmodule Reports.Orders.Order do
  @moduledoc false

  @enforce_keys [:customer_id, :amount, :currency, :placed_on, :status]
  defstruct [:customer_id, :amount, :currency, :placed_on, :status]

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_on: Date.t(),
          status: :completed | :refunded | :pending
        }
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

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

  @doc """
  Builds the report for a list of orders.

  For each customer, `:totals` holds the amount spent per currency across
  completed orders, and `:last_order_on` is the UTC date of their most recent
  order of any status. `:top_customers` lists up to five `{customer_id, count}`
  pairs, ordered by number of completed orders, then by customer id.

  Returns `{:error, reason}` for the first order that cannot be parsed.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.01",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "7.00",
      ...>     "currency" => "USD",
      ...>     "placed_at" => "2024-03-07T10:00:00Z",
      ...>     "status" => "refunded"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-07]
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("25.00")
      iex> report.top_customers
      [{"c1", 2}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_order, %{"customer_id" => "c1"}}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} ->
        {:ok, summarize(orders)}

      {:error, _reason} = error ->
        error
    end
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(completed)}
  end

  defp summarize_customer(orders) do
    totals =
      orders
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, currency_orders} ->
        {currency, sum_amounts(currency_orders)}
      end)

    last_order_on =
      orders
      |> Enum.map(& &1.placed_on)
      |> Enum.max(Date)

    %{totals: totals, last_order_on: last_order_on}
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp top_customers(completed_orders) do
    completed_orders
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_order(
         %{
           "customer_id" => customer_id,
           "amount" => amount,
           "currency" => currency,
           "placed_at" => placed_at,
           "status" => status
         } = row
       )
       when is_binary(customer_id) and is_binary(currency) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_on} <- parse_placed_on(placed_at),
         {:ok, status} <- parse_status(status) do
      order = %Order{
        customer_id: customer_id,
        amount: amount,
        currency: currency,
        placed_on: placed_on,
        status: status
      }

      {:ok, order}
    else
      {:error, reason} -> {:error, {:invalid_order, reason, row}}
    end
  end

  defp parse_order(row), do: {:error, {:invalid_order, row}}

  defp parse_amount(text) when is_binary(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_other), do: {:error, {:invalid_field, "amount"}}

  defp parse_placed_on(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_on(_other), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}
end
