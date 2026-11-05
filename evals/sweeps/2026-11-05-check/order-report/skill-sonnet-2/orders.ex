defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
  """

  defmodule Order do
    @moduledoc false

    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys

    @type status :: :completed | :refunded | :pending

    @type t :: %__MODULE__{
            customer_id: String.t(),
            amount: Decimal.t(),
            currency: String.t(),
            placed_at: DateTime.t(),
            status: status()
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
  Builds the report for a list of orders.

  The report holds two keys:

    * `:customers` - for each customer id, `:totals` (the sum of completed
      orders per currency) and `:last_order_on` (the date of the most recent
      order of any status).
    * `:top_customers` - up to 5 `{customer_id, completed_count}` pairs, most
      completed orders first. Ties are broken by customer id.

  A customer with no completed orders has empty `:totals`. Returns
  `{:error, reason}` for the first order that cannot be parsed.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("25.00")
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{totals: totals_by_currency(orders), last_order_on: DateTime.to_date(latest.placed_at)}
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum_decimals(amounts)} end)
  end

  defp sum_decimals(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp parse_orders(rows) do
    results = Enum.map(rows, &parse_order/1)

    case Enum.find(results, &match?({:error, _reason}, &1)) do
      nil ->
        {:ok, Enum.map(results, fn {:ok, order} -> order end)}

      {:error, _reason} = error ->
        error
    end
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
      {:ok, value} when is_binary(value) ->
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

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
