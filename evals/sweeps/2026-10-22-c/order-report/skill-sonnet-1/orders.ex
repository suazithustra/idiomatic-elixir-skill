defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Orders arrive as string-keyed maps and are converted to `Reports.Orders.Order`
  structs before any aggregation happens.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

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
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report for a list of string-keyed order maps.

  The report holds:

    * `:customers` - for each customer id, `:totals` (amount spent per currency
      across completed orders) and `:last_order_on` (the date of their most
      recent order, whatever its status)
    * `:top_customers` - up to #{@top_customer_count} `{customer_id, completed_orders}` pairs,
      most completed orders first, ties broken by customer id

  Returns `{:error, {:invalid_order, index, reason}}` for the first malformed
  order, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.00", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-03T10:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-05-03]
      iex> report.top_customers
      [{"c1", 1}]
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
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
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
    case row do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{} -> {:error, {:missing_field, key}}
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
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    orders_by_customer = Enum.group_by(orders, & &1.customer_id)

    customers =
      Map.new(orders_by_customer, fn {id, orders} -> {id, summarize_customer(orders)} end)

    %{customers: customers, top_customers: top_customers(orders_by_customer)}
  end

  defp summarize_customer(orders) do
    last_placed_at = Enum.max_by(orders, & &1.placed_at, DateTime).placed_at

    %{totals: totals_by_currency(orders), last_order_on: DateTime.to_date(last_placed_at)}
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} ->
      {currency, Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(orders_by_customer) do
    orders_by_customer
    |> Enum.map(fn {id, orders} -> {id, Enum.count(orders, &(&1.status == :completed))} end)
    |> Enum.reject(fn {_id, completed} -> completed == 0 end)
    |> Enum.sort_by(fn {id, completed} -> {-completed, id} end)
    |> Enum.take(@top_customer_count)
  end
end
