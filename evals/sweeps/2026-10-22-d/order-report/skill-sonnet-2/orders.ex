defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
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
  Builds the report for a list of orders.

  Per customer, `:totals` holds the amount spent per currency across completed
  orders and `:last_order_on` the UTC date of their most recent order, whatever
  its status. `:top_customers` lists up to five `{customer_id, completed_count}`
  pairs, most completed orders first, ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order, counted
  from zero, that is malformed.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "9.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-07T10:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-07]
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("25.00")
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &parse_indexed/2)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_indexed({row, index}, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parse_amount(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parse_placed_at(row),
         {:ok, status} <- parse_status(row) do
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
    case row do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(row) do
    with {:ok, text} <- string_field(row, "amount") do
      case Decimal.parse(text) do
        {amount, ""} -> {:ok, amount}
        {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
        :error -> {:error, {:invalid_field, "amount"}}
      end
    end
  end

  defp parse_placed_at(row) do
    with {:ok, text} <- string_field(row, "placed_at") do
      case DateTime.from_iso8601(text) do
        {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
        {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
      end
    end
  end

  defp parse_status(row) do
    with {:ok, text} <- string_field(row, "status") do
      status_atom(text)
    end
  end

  defp status_atom("completed"), do: {:ok, :completed}
  defp status_atom("refunded"), do: {:ok, :refunded}
  defp status_atom("pending"), do: {:ok, :pending}
  defp status_atom(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    by_customer = Enum.group_by(orders, & &1.customer_id)

    %{
      customers: Map.new(by_customer, fn {id, orders} -> {id, summarize_customer(orders)} end),
      top_customers: top_customers(by_customer)
    }
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
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(by_customer) do
    by_customer
    |> Enum.map(fn {id, orders} -> {id, Enum.count(orders, &(&1.status == :completed))} end)
    |> Enum.filter(fn {_id, completed_count} -> completed_count > 0 end)
    |> Enum.sort_by(fn {id, completed_count} -> {-completed_count, id} end)
    |> Enum.take(@top_customer_count)
  end
end
