defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders as parsed from CSV.

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

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customer_count 5

  @doc """
  Builds the report from a list of order maps.

  `:customers` maps each customer id to the total spent per currency across
  completed orders and the date of their most recent order, whatever its
  status. `:top_customers` lists up to five `{customer_id, completed_orders}`
  pairs, most orders first, ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first malformed
  order, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-03T10:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-05-03]
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, t()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &accumulate_order/2)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp accumulate_order({row, index}, {:ok, orders}) do
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
      status_from_string(text)
    end
  end

  defp status_from_string("completed"), do: {:ok, :completed}
  defp status_from_string("refunded"), do: {:ok, :refunded}
  defp status_from_string("pending"), do: {:ok, :pending}
  defp status_from_string(_other), do: {:error, {:invalid_field, "status"}}

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
    last_order = Enum.max_by(orders, & &1.placed_at, DateTime)

    totals =
      orders
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.group_by(& &1.currency)
      |> Map.new(fn {currency, currency_orders} ->
        {currency, sum_amounts(currency_orders)}
      end)

    %{totals: totals, last_order_on: DateTime.to_date(last_order.placed_at)}
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
end
