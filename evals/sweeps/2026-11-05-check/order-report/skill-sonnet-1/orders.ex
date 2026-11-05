defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

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

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @top_customer_count 5

  @doc """
  Builds the report from a list of string-keyed order maps.

  `:customers` maps each customer id to the total spent per currency across
  completed orders and the date of their most recent order. The most recent
  order counts whatever its status, and its date is the UTC date of
  `"placed_at"`. A customer with no completed orders has empty `:totals`.

  `:top_customers` lists up to five `{customer_id, completed_order_count}`
  pairs, highest count first, with ties broken by customer id.

  Returns `{:error, reason}` for the first order that is malformed, with
  `reason` being `{:missing_field, key}`, `{:invalid_field, key}` or
  `{:invalid_order, order}`.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.top_customers
      [{"c1", 1}]
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-01]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rest], orders) do
    with {:ok, order} <- parse_order(row) do
      parse_orders(rest, [order | orders])
    end
  end

  defp parse_order(
         %{
           "customer_id" => _customer_id,
           "amount" => _amount,
           "currency" => _currency,
           "placed_at" => _placed_at,
           "status" => _status
         } = row
       ) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parse_amount(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parse_placed_at(row),
         {:ok, status} <- parse_status(row) do
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

  defp parse_order(row) when is_map(row), do: {:error, {:missing_field, first_missing_key(row)}}
  defp parse_order(other), do: {:error, {:invalid_order, other}}

  defp first_missing_key(row) do
    Enum.find(
      ["customer_id", "amount", "currency", "placed_at", "status"],
      &(not Map.has_key?(row, &1))
    )
  end

  defp string_field(row, key) do
    case Map.fetch!(row, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _value ->
        {:error, {:invalid_field, key}}
    end
  end

  defp parse_amount(row) do
    with {:ok, text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_decimal(text) do
      {:ok, amount}
    end
  end

  defp parse_decimal(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_placed_at(row) do
    with {:ok, text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(text) do
      {:ok, placed_at}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status(row) do
    with {:ok, text} <- string_field(row, "status") do
      status_from_string(text)
    end
  end

  defp status_from_string("completed"), do: {:ok, :completed}
  defp status_from_string("refunded"), do: {:ok, :refunded}
  defp status_from_string("pending"), do: {:ok, :pending}
  defp status_from_string(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %{totals: totals_per_currency(orders), last_order_on: last_order_on(orders)}
  end

  defp totals_per_currency(orders) do
    orders
    |> completed()
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> completed()
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed(orders), do: Enum.filter(orders, &(&1.status == :completed))
end
