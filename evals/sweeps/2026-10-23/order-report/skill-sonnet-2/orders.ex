defmodule Reports.Orders do
  @moduledoc """
  Builds a report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

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

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t(),
          completed_orders: non_neg_integer()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [%{customer_id: String.t(), completed_orders: pos_integer()}]
        }

  @doc """
  Builds the report for a list of orders.

  `customers` maps each customer id to the total spent per currency across
  completed orders and the date of their most recent order, whatever its
  status. A customer with no completed orders has empty `totals`.

  `top_customers` lists up to #{@top_customer_count} customers with the most
  completed orders, ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order
  that cannot be parsed. `index` is the position of the order in the list.

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
      [%{customer_id: "c1", completed_orders: 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(orders) do
    case parse_orders(orders) do
      {:ok, parsed} -> {:ok, summarize(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(orders) do
    parsed =
      orders
      |> Enum.with_index()
      |> Enum.map(fn {order, index} -> {index, parse_order(order)} end)

    case Enum.find(parsed, &match?({_index, {:error, _reason}}, &1)) do
      nil -> {:ok, Enum.map(parsed, fn {_index, {:ok, order}} -> order end)}
      {index, {:error, reason}} -> {:error, {:invalid_order, index, reason}}
    end
  end

  defp parse_order(
         %{
           "customer_id" => customer_id,
           "amount" => amount,
           "currency" => currency,
           "placed_at" => placed_at,
           "status" => status
         } = _order
       ) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_placed_at(placed_at),
         {:ok, status} <- parse_status(status) do
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

  defp parse_order(_order), do: {:error, :missing_field}

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
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_at(_text), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

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
      totals: total_per_currency(completed),
      last_order_on: DateTime.to_date(last_order_at),
      completed_orders: length(completed)
    }
  end

  defp total_per_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_orders > 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_orders, customer_id} end)
    |> Enum.take(@top_customer_count)
    |> Enum.map(fn {customer_id, summary} ->
      %{customer_id: customer_id, completed_orders: summary.completed_orders}
    end)
  end
end
