defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a map with string keys: `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601 datetime)
  and `"status"` (`"completed"`, `"refunded"` or `"pending"`).

  Rows are parsed into `Reports.Orders.Order` structs before any totals are
  computed, so one malformed row fails the whole report and names the field
  that caused it.
  """

  @top_count 5

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  defmodule Summary do
    @moduledoc false
    @enforce_keys [:spent, :last_order_on, :completed_count]
    defstruct @enforce_keys
  end

  @doc """
  Builds the report from raw CSV rows.

  Returns `{:ok, report}`, or `{:error, reason}` for the first invalid row.
  The report is a map with:

    * `:customers` - a map from `customer_id` to a `Summary` with `:spent`
      (a map from currency to a `Decimal` total over completed orders),
      `:last_order_on` (the latest `Date` among all of the customer's orders,
      whatever their status) and `:completed_count`
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      highest count first; ties are ordered by `customer_id`

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}

  """
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_row(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_row(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
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
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_status), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(customer_orders) do
    completed = Enum.filter(customer_orders, &completed?/1)

    %Summary{
      spent: spent_by_currency(completed),
      last_order_on: last_order_on(customer_orders),
      completed_count: length(completed)
    }
  end

  defp completed?(order), do: order.status == :completed

  defp spent_by_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, &Decimal.add/2)}
    end)
  end

  defp last_order_on(customer_orders) do
    customer_orders
    |> Enum.map(&DateTime.to_date(&1.placed_at))
    |> Enum.max(Date)
  end

  defp top_customers(customers) do
    customers
    |> Enum.sort_by(fn {customer_id, summary} ->
      {-summary.completed_count, customer_id}
    end)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
  end
end
