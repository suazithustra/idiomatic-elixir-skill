defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from CSV-parsed order maps.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Orders are validated and turned
  into `Reports.Orders.Order` structs before any aggregation happens.
  """

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
          top_customers: [{String.t(), pos_integer()}]
        }

  @type error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Builds the report for a list of orders.

  The report has two parts:

    * `:customers` - for each customer id, `:totals` (total spent per currency
      across completed orders) and `:last_order_on` (the date of their most
      recent order, whatever its status). A customer with no completed orders
      has empty totals.
    * `:top_customers` - up to #{@top_customer_count} `{customer_id, completed_count}`
      pairs, most completed orders first. Ties are broken by customer id.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first malformed order.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T09:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "99.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-07T09:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("15.00")}
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-07]
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} ->
        {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{
      totals: totals_per_currency(orders),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_per_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(&DateTime.to_date(&1.placed_at))
    |> Enum.max(Date)
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
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
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
end
