defmodule Reports.Orders do
  @moduledoc """
  Builds per-customer totals and a top-customers ranking from parsed CSV order rows.

  Amounts are kept as `Decimal` values so that sums are exact.
  """

  @top_size 5

  defmodule Order do
    @moduledoc "One parsed order row."
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  defmodule Customer do
    @moduledoc "One customer's summary across all of their orders."
    defstruct [:customer_id, :totals, :completed_count, :last_order_on]
  end

  @doc """
  Builds the report from string-keyed order rows.

  Returns `{:ok, report}` where `report` is a map with:

    * `:customers` - every customer, sorted by `customer_id`
    * `:top_customers` - up to five customers with at least one completed
      order, ranked by completed orders; ties are broken by `customer_id`

  `:totals` (currency to `Decimal`) counts completed orders only.
  `:last_order_on` (a `Date`) uses all orders, whatever their status.

  Returns `{:error, reason}` for the first row that does not parse.
  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | orders]}}

        {:error, _reason} = error ->
          {:halt, error}
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
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  # The offset is required: a value without one is rejected, not guessed as UTC.
  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
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
      |> Enum.map(&summarize_customer/1)
      |> Enum.sort_by(& &1.customer_id)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer({customer_id, orders}) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %Customer{
      customer_id: customer_id,
      totals: totals_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on: last_order_on(orders)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(&DateTime.to_date(&1.placed_at))
    |> Enum.max(Date)
  end

  defp top_customers(customers) do
    customers
    |> Enum.filter(&(&1.completed_count > 0))
    |> Enum.sort_by(&{-&1.completed_count, &1.customer_id})
    |> Enum.take(@top_size)
  end
end
