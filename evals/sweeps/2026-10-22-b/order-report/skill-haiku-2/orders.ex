defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a string-keyed map with `"customer_id"`, `"amount"` (a decimal
  string), `"currency"`, `"placed_at"` (an ISO 8601 datetime with a UTC offset),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).
  """

  @top_count 5

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

  @typedoc "Totals and activity for one customer."
  @type customer_summary :: %{
          customer_id: String.t(),
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: [customer_summary()],
          top_customers: [customer_summary()]
        }

  @doc """
  Builds the report from parsed CSV rows.

  `totals` and `completed_count` count completed orders only. `last_order_at`
  is the latest `placed_at` across all of the customer's orders, whatever their
  status. `top_customers` holds up to five customers with at least one
  completed order, ordered by completed count and then by `customer_id`.

  Returns `{:error, reason}` for the first row with a missing, invalid, or
  unknown field. The reason names the field, such as `{:invalid_field, "amount"}`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2026-01-05T10:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> [customer] = report.top_customers
      iex> {customer.customer_id, customer.completed_count, Decimal.to_string(customer.totals["EUR"])}
      {"c1", 1, "19.99"}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, report(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp report(orders) do
    customers =
      for {customer_id, customer_orders} <- Enum.group_by(orders, & &1.customer_id) do
        summarize(customer_id, customer_orders)
      end

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize(customer_id, orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customer_id: customer_id,
      totals: totals_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_at: orders |> Enum.map(& &1.placed_at) |> Enum.max(DateTime)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum_amounts(amounts)} end)
  end

  defp sum_amounts(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp top_customers(customers) do
    customers
    |> Enum.filter(&(&1.completed_count > 0))
    |> Enum.sort_by(&{-&1.completed_count, &1.customer_id})
    |> Enum.take(@top_count)
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
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_text),
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
      {amount, ""} -> if Decimal.finite?(amount), do: {:ok, amount}, else: invalid_amount()
      _ -> invalid_amount()
    end
  end

  defp invalid_amount, do: {:error, {:invalid_field, "amount"}}

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
