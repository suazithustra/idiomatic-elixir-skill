defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Orders are parsed into
  `Reports.Orders.Order` structs before any totals are computed, so a bad row
  is reported instead of producing wrong numbers.
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
  Builds the report for a list of orders.

  For each customer, `:totals` holds the amount spent per currency across
  completed orders and `:last_order_on` the date of their latest order of any
  status. `:top_customers` lists up to #{@top_customer_count} `{customer_id, completed_count}`
  pairs, most completed orders first, ties broken by customer id.

  Returns `{:error, {:invalid_field, field}}` for the first order with an
  unparseable field and `{:error, :invalid_order}` for one missing a key.

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
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T09:30:00Z",
      ...>     "status" => "pending"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> Decimal.to_string(report.customers["c1"].totals["EUR"])
      "19.99"
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      report = %{
        customers: customer_summaries(orders),
        top_customers: top_customers(orders)
      }

      {:ok, report}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rest, [order | orders])
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
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_text), do: {:error, {:invalid_field, "amount"}}

  defp parse_placed_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_at(_text), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{totals: totals_by_currency(orders), last_order_on: DateTime.to_date(latest.placed_at)}
  end

  defp totals_by_currency(orders) do
    orders
    |> completed()
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
