defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

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
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customer_count 5

  @doc """
  Builds the report for a list of orders.

  `:customers` maps each customer id to the total spent per currency on
  completed orders and the time of their most recent order, whatever its
  status. `:top_customers` lists up to #{@top_customer_count} `{customer_id, completed_count}`
  pairs, most completed orders first, ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first malformed
  order, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-06-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "9.00", "currency" => "EUR",
      ...>     "placed_at" => "2024-07-01T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("15.00")
      iex> report.customers["c1"].last_order_at
      ~U[2024-07-01 10:00:00Z]
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(orders) do
    with {:ok, orders} <- parse_orders(orders) do
      {:ok, %{customers: customer_summaries(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(raw_orders) do
    raw_orders
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {raw_order, index}, {:ok, parsed} ->
      case parse_order(raw_order) do
        {:ok, order} -> {:cont, {:ok, [order | parsed]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(%{} = raw) do
    with {:ok, customer_id} <- string_field(raw, "customer_id"),
         {:ok, amount} <- parse_amount(raw),
         {:ok, currency} <- string_field(raw, "currency"),
         {:ok, placed_at} <- parse_placed_at(raw),
         {:ok, status} <- parse_status(raw) do
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

  defp parse_order(_raw), do: {:error, :not_a_map}

  defp string_field(raw, key) do
    case raw do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => value} -> {:error, {:invalid_field, key, value}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(raw) do
    with {:ok, amount} <- string_field(raw, "amount") do
      case Decimal.parse(amount) do
        {decimal, ""} -> {:ok, decimal}
        _ -> {:error, {:invalid_field, "amount", amount}}
      end
    end
  end

  defp parse_placed_at(raw) do
    with {:ok, placed_at} <- string_field(raw, "placed_at") do
      case DateTime.from_iso8601(placed_at) do
        {:ok, datetime, _utc_offset} -> {:ok, datetime}
        {:error, _reason} -> {:error, {:invalid_field, "placed_at", placed_at}}
      end
    end
  end

  defp parse_status(raw) do
    with {:ok, status} <- string_field(raw, "status") do
      case status do
        "completed" -> {:ok, :completed}
        "refunded" -> {:ok, :refunded}
        "pending" -> {:ok, :pending}
        other -> {:error, {:invalid_field, "status", other}}
      end
    end
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(customer_orders) do
    %{
      totals: totals_by_currency(customer_orders),
      last_order_at: Enum.max_by(customer_orders, & &1.placed_at, DateTime).placed_at
    }
  end

  defp totals_by_currency(customer_orders) do
    customer_orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
