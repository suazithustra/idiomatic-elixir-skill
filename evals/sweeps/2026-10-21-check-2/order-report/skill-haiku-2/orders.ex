defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows parsed from CSV.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime),
  and `"status"` (`"completed"`, `"refunded"`, or `"pending"`).

  The report has two parts:

    * `:customers` - one summary per customer, sorted by `customer_id`. Each
      summary has the completed-order total per currency (`:spent`), the number
      of completed orders (`:completed_count`), and the date of the latest order
      of any status (`:last_order_on`).
    * `:top_customers` - up to five customers with at least one completed
      order, most completed orders first. Ties keep `customer_id` order.
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

  @doc """
  Builds the report from a list of CSV rows.

  Returns `{:error, reason}` for the first row with a missing or invalid field.

  ## Examples

      iex> {:ok, report} =
      ...>   Reports.Orders.build([
      ...>     %{"customer_id" => "c1", "amount" => "10.00", "currency" => "EUR",
      ...>       "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"}
      ...>   ])
      iex> [customer] = report.customers
      iex> customer.completed_count
      1
  """
  @spec build([map()]) :: {:ok, %{customers: [map()], top_customers: [map()]}} | {:error, term()}
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, report(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp report(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Enum.map(fn {customer_id, customer_orders} ->
        summarize(customer_id, customer_orders)
      end)
      |> Enum.sort_by(& &1.customer_id)

    top_customers =
      customers
      |> Enum.filter(&(&1.completed_count > 0))
      |> Enum.sort_by(& &1.completed_count, :desc)
      |> Enum.take(@top_count)

    %{customers: customers, top_customers: top_customers}
  end

  defp summarize(customer_id, orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customer_id: customer_id,
      spent: spent_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on:
        orders
        |> Enum.map(& &1.placed_at)
        |> Enum.max(DateTime)
        |> DateTime.to_date()
    }
  end

  defp spent_by_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp parse_rows(rows) do
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
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      _other -> {:error, {:invalid_field, "amount"}}
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
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
