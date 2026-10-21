defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime) and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Only completed orders count toward spend and the top-customer ranking.
  Every order, whatever its status, counts toward the last order date.
  """

  @top_count 5

  @empty_summary %{spent: %{}, completed_count: 0, last_order_on: nil}

  defmodule Order do
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

  @typedoc "Totals and dates for one customer."
  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_on: Date.t()
        }

  @typedoc """
  `customers` maps each customer ID to its summary. `top_customers` lists up
  to five `{customer_id, completed_count}` tuples, most completed orders first.
  """
  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from order rows.

  Returns `{:error, reason}` for the first row with a missing field, an
  unreadable amount or date, or an unknown status.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = summarize(orders)
      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- fetch_field(row, "customer_id"),
         {:ok, amount_text} <- fetch_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- fetch_field(row, "currency"),
         {:ok, placed_at_text} <- fetch_field(row, "placed_at"),
         {:ok, placed_on} <- parse_date(placed_at_text),
         {:ok, status_text} <- fetch_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      {:ok,
       %Order{
         customer_id: customer_id,
         amount: amount,
         currency: currency,
         placed_on: placed_on,
         status: status
       }}
    end
  end

  defp fetch_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) when is_binary(text) do
    case Decimal.parse(text) do
      # Finite decimals have an integer coefficient; NaN and infinity do not.
      {%Decimal{coef: coef} = amount, ""} when is_integer(coef) -> {:ok, amount}
      _ -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_other), do: {:error, {:invalid_field, "amount"}}

  defp parse_date(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, DateTime.to_date(placed_at)}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_date(_other), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    Enum.reduce(orders, %{}, fn order, customers ->
      summary = Map.get(customers, order.customer_id, @empty_summary)
      Map.put(customers, order.customer_id, add_order(summary, order))
    end)
  end

  defp add_order(summary, order) do
    summary = %{summary | last_order_on: latest_date(summary.last_order_on, order.placed_on)}

    if order.status == :completed do
      %{
        summary
        | spent: add_spend(summary.spent, order),
          completed_count: summary.completed_count + 1
      }
    else
      summary
    end
  end

  defp latest_date(nil, date), do: date
  defp latest_date(current, date), do: Enum.max([current, date], Date)

  defp add_spend(spent, order) do
    Map.update(spent, order.currency, order.amount, &Decimal.add(&1, order.amount))
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(fn {_customer_id, summary} -> summary.completed_count > 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_count, customer_id} end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
  end
end
