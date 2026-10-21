defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from parsed CSV order rows.

  Each row is a map with string keys `"customer_id"`, `"amount"`, `"currency"`,
  `"placed_at"` and `"status"`.
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
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [%{customer_id: String.t(), completed_orders: pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  For each customer, `totals` is the amount spent per currency across completed
  orders (empty if the customer has none) and `last_order_on` is the UTC date of
  their most recent order of any status. `top_customers` lists the customers with
  the most completed orders, highest first, ties broken by customer id.

  Returns `{:error, {index, reason}}` for the first row that is malformed, where
  `index` is its zero-based position.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.00", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> report.top_customers
      [%{customer_id: "c1", completed_orders: 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {non_neg_integer(), term()}}
  def build(orders) do
    with {:ok, orders} <- parse_orders(orders) do
      summaries = Enum.reduce(orders, %{}, &add_order/2)

      {:ok,
       %{
         customers:
           Map.new(summaries, fn {customer_id, summary} -> {customer_id, public(summary)} end),
         top_customers: top_customers(summaries)
       }}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, parsed} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | parsed]}}
        {:error, reason} -> {:halt, {:error, {index, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- fetch_field(row, "customer_id"),
         {:ok, amount} <- fetch_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- fetch_field(row, "currency"),
         {:ok, placed_at} <- fetch_field(row, "placed_at", &parse_datetime/1),
         {:ok, status} <- fetch_field(row, "status", &parse_status/1) do
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

  defp fetch_field(row, key, parser \\ &{:ok, &1}) do
    with {:ok, value} <- Map.fetch(row, key) |> missing_field(key),
         {:ok, parsed} <- parser.(value) do
      {:ok, parsed}
    else
      {:error, :invalid} -> {:error, {:invalid_field, key}}
      {:error, _} = error -> error
    end
  end

  defp missing_field({:ok, _} = found, _key), do: found
  defp missing_field(:error, key), do: {:error, {:missing_field, key}}

  defp parse_amount(value) when is_binary(value) do
    case Decimal.parse(value) do
      {amount, ""} -> {:ok, amount}
      _ -> {:error, :invalid}
    end
  end

  defp parse_amount(_value), do: {:error, :invalid}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, :invalid}

  defp add_order(%Order{} = order, summaries) do
    summary =
      Map.get(summaries, order.customer_id, %{
        totals: %{},
        completed_orders: 0,
        last_order_at: nil
      })

    Map.put(summaries, order.customer_id, %{
      totals: add_total(summary.totals, order),
      completed_orders: summary.completed_orders + completed_count(order),
      last_order_at: latest(summary.last_order_at, order.placed_at)
    })
  end

  defp add_total(totals, %Order{status: :completed, currency: currency, amount: amount}) do
    Map.update(totals, currency, amount, &Decimal.add(&1, amount))
  end

  defp add_total(totals, %Order{}), do: totals

  defp completed_count(%Order{status: :completed}), do: 1
  defp completed_count(%Order{}), do: 0

  defp latest(nil, placed_at), do: placed_at

  defp latest(current, placed_at) do
    if DateTime.after?(placed_at, current), do: placed_at, else: current
  end

  defp public(summary) do
    %{totals: summary.totals, last_order_on: DateTime.to_date(summary.last_order_at)}
  end

  defp top_customers(summaries) do
    for(
      {customer_id, %{completed_orders: count}} when count > 0 <- summaries,
      do: {customer_id, count}
    )
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end
end
