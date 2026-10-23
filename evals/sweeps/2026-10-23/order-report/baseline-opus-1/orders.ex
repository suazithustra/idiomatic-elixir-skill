defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys:

    * `"customer_id"` - non-empty string
    * `"amount"` - decimal string, such as `"19.99"`
    * `"currency"` - ISO 4217 code, such as `"EUR"`
    * `"placed_at"` - ISO 8601 datetime with a UTC offset, such as
      `"2024-03-01T10:15:00Z"` or `"2024-03-01T12:15:00+02:00"`
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  Amounts are parsed into `Decimal` so totals are exact. Currency codes stay
  strings: they come from external input and are never turned into atoms.

  Datetimes without an offset are rejected rather than guessed, because the
  same wall-clock time can fall on different dates in different time zones.
  """

  @top_count 5

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          totals: %{currency() => Decimal.t()},
          completed_orders: non_neg_integer(),
          last_order_on: Date.t()
        }

  @type top_customer :: %{customer_id: customer_id(), completed_orders: pos_integer()}

  @type report :: %{
          customers: %{customer_id() => customer_summary()},
          top_customers: [top_customer()]
        }

  @type error_reason ::
          :not_a_map
          | {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @doc """
  Builds the report.

  For each customer the report holds:

    * `:totals` - amount spent per currency, counting completed orders only.
      A customer with no completed orders has an empty map.
    * `:completed_orders` - number of completed orders.
    * `:last_order_on` - UTC date of the customer's most recent order of any
      status, since pending and refunded orders were still placed.

  `:top_customers` lists up to #{@top_count} customers with at least one
  completed order, by completed order count descending. Ties are broken by
  customer id ascending so the result is deterministic.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, where `index` is the row's zero-based position in `rows`.

  ## Examples

      iex> Reports.Orders.build([
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:15:00Z", "status" => "completed"}
      ...> ])
      {:ok,
       %{
         customers: %{
           "c1" => %{
             totals: %{"EUR" => Decimal.new("19.99")},
             completed_orders: 1,
             last_order_on: ~D[2024-03-01]
           }
         },
         top_customers: [%{customer_id: "c1", completed_orders: 1}]
       }}

  """
  @spec build(Enumerable.t(map())) ::
          {:ok, report()}
          | {:error, {:invalid_order, non_neg_integer(), error_reason()}}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = summarize(orders)
      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  ## Parsing

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
  end

  defp parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- fetch_string(row, "customer_id"),
         {:ok, amount} <- parse_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- parse_field(row, "currency", &parse_currency/1),
         {:ok, placed_at} <- parse_field(row, "placed_at", &parse_datetime/1),
         {:ok, status} <- parse_field(row, "status", &parse_status/1) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse_order(_row), do: {:error, :not_a_map}

  defp fetch_string(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_field(row, key, parser) do
    with {:ok, value} <- fetch_string(row, key) do
      case parser.(value) do
        {:ok, parsed} -> {:ok, parsed}
        :error -> {:error, {:invalid_field, key, value}}
      end
    end
  end

  defp parse_amount(value) do
    case Decimal.parse(value) do
      {amount, ""} ->
        if Decimal.inf?(amount) or Decimal.nan?(amount), do: :error, else: {:ok, amount}

      _ ->
        :error
    end
  end

  defp parse_currency(<<a, b, c>> = code) when a in ?A..?Z and b in ?A..?Z and c in ?A..?Z,
    do: {:ok, code}

  defp parse_currency(_value), do: :error

  # DateTime.from_iso8601/1 shifts the result to UTC, so dates derived from it
  # are UTC dates regardless of the offset in the source string.
  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_value), do: :error

  ## Aggregation

  defp summarize(orders) do
    orders
    |> Enum.reduce(%{}, fn order, acc ->
      summary =
        Map.get(acc, order.customer_id, %{totals: %{}, completed_orders: 0, last_order_at: nil})

      Map.put(acc, order.customer_id, add_order(summary, order))
    end)
    |> Map.new(fn {customer_id, summary} ->
      {customer_id,
       %{
         totals: summary.totals,
         completed_orders: summary.completed_orders,
         last_order_on: DateTime.to_date(summary.last_order_at)
       }}
    end)
  end

  defp add_order(summary, order) do
    summary
    |> track_latest(order.placed_at)
    |> add_if_completed(order)
  end

  defp track_latest(%{last_order_at: nil} = summary, placed_at),
    do: %{summary | last_order_at: placed_at}

  defp track_latest(%{last_order_at: latest} = summary, placed_at) do
    if DateTime.after?(placed_at, latest),
      do: %{summary | last_order_at: placed_at},
      else: summary
  end

  defp add_if_completed(summary, %{status: :completed, currency: currency, amount: amount}) do
    %{
      summary
      | completed_orders: summary.completed_orders + 1,
        totals: Map.update(summary.totals, currency, amount, &Decimal.add(&1, amount))
    }
  end

  defp add_if_completed(summary, _order), do: summary

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_orders > 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_orders, customer_id} end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} ->
      %{customer_id: customer_id, completed_orders: summary.completed_orders}
    end)
  end
end
