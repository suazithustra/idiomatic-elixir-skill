defmodule Reports.Orders.Order do
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

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime
  with a UTC offset), and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Totals and the top customers count completed orders only. The last order date
  covers every order a customer placed, whatever its status.
  """

  alias Reports.Orders.Order

  @top_count 5

  @typedoc """
  The report: `customers` maps each customer ID to `:totals` (a map of currency
  to `Decimal` total over completed orders), `:completed_count`, and
  `:last_placed_at`. `top_customers` lists `{customer_id, completed_count}`,
  highest count first, at most #{@top_count} entries.
  """
  @type report :: %{
          customers: %{String.t() => map()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report for a list of CSV rows.

  Returns `{:error, {:invalid_row, number, reason}}` for the first row that
  fails to parse, where `number` is its 1-based position in `rows`.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_rows(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, number}, {:ok, orders} ->
      case parse_row(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, {:invalid_row, number, reason}}}
      end
    end)
  end

  defp parse_row(%{
         "customer_id" => customer_id,
         "amount" => amount_text,
         "currency" => currency,
         "placed_at" => placed_text,
         "status" => status_text
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_placed_at(placed_text),
         {:ok, status} <- parse_status(status_text) do
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

  defp parse_row(_row), do: {:error, :invalid_row}

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

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, customer_summary(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp customer_summary(customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == :completed))

    %{
      totals: totals_by_currency(completed),
      completed_count: length(completed),
      last_placed_at: last_placed_at(customer_orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
    end)
  end

  defp last_placed_at(customer_orders) do
    customer_orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.filter(fn {_customer_id, count} -> count > 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end
end
