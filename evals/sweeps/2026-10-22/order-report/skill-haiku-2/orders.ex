defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Amounts are kept as `Decimal` so sums stay exact.
  """

  @top_count 5

  @typedoc "A summarized customer as it appears in `:customers`."
  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [%{customer_id: String.t(), completed_orders: pos_integer()}]
        }

  defmodule Order do
    @moduledoc false

    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct [:customer_id, :amount, :currency, :placed_at, :status]

    @type t :: %__MODULE__{
            customer_id: String.t(),
            amount: Decimal.t(),
            currency: String.t(),
            placed_at: DateTime.t(),
            status: :completed | :refunded | :pending
          }
  end

  @doc """
  Builds the report from string-keyed order rows.

  Returns `{:error, reason}` when a row has a missing or invalid field.

  ## Report

    * `:customers` - maps each customer ID to `%{spent: %{currency => Decimal}, last_order_at: DateTime}`.
      `spent` sums completed orders only. `last_order_at` is the latest order of any status.
    * `:top_customers` - up to five `%{customer_id: id, completed_orders: count}` maps, most completed orders first.

  ## Examples

      iex> {:ok, report} =
      ...>   Reports.Orders.build([
      ...>     %{"customer_id" => "c1", "amount" => "10.00", "currency" => "EUR",
      ...>       "placed_at" => "2024-01-05T10:00:00Z", "status" => "completed"},
      ...>     %{"customer_id" => "c1", "amount" => "5.50", "currency" => "EUR",
      ...>       "placed_at" => "2024-01-06T10:00:00Z", "status" => "refunded"}
      ...>   ])
      iex> Decimal.to_string(report.customers["c1"].spent["EUR"])
      "10.00"
      iex> report.top_customers
      [%{customer_id: "c1", completed_orders: 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
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
      {customer_id,
       %{
         spent: spent_by_currency(customer_orders),
         last_order_at: last_order_at(customer_orders)
       }}
    end)
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {_customer_id, count} -> count end, :desc)
    |> Enum.take(@top_count)
    |> Enum.map(fn {customer_id, count} ->
      %{customer_id: customer_id, completed_orders: count}
    end)
  end

  defp completed?(%Order{status: status}), do: status == :completed

  defp parse_orders(rows) do
    case Enum.reduce_while(rows, {:ok, []}, &collect_order/2) do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp collect_order(row, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
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
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
