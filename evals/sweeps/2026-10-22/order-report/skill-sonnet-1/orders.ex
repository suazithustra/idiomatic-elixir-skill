defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.

  The report has two parts:

    * `:customers` - for each customer, the total spent per currency across
      completed orders (`:totals`) and the date of their most recent order
      (`:last_order_on`). The most recent order counts orders of any status.
      A customer with no completed orders has empty `:totals`.
    * `:top_customers` - up to 5 `{customer_id, completed_orders}` tuples,
      ordered by number of completed orders, highest first. Ties are broken by
      customer id so the result is stable.
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

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Builds the report from a list of string-keyed order maps.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order that
  is malformed, where `index` is its position in the list and `reason` is
  `{:missing_field, key}` or `{:invalid_field, key}`.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T09:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "99.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-07T09:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-07]
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("15.00")}
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, t()} | {:error, {:invalid_order, non_neg_integer(), error()}}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, parsed} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | parsed]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
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
    case row do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
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
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    by_customer = Enum.group_by(orders, & &1.customer_id)

    %{
      customers:
        Map.new(by_customer, fn {customer_id, orders} ->
          {customer_id, summarize_customer(orders)}
        end),
      top_customers: top_customers(by_customer)
    }
  end

  defp summarize_customer(orders) do
    last_order = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_by_currency(orders),
      last_order_on: DateTime.to_date(last_order.placed_at)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} ->
      {currency, Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(by_customer) do
    by_customer
    |> Enum.map(fn {customer_id, orders} ->
      {customer_id, Enum.count(orders, &(&1.status == :completed))}
    end)
    |> Enum.reject(fn {_customer_id, completed} -> completed == 0 end)
    |> Enum.sort_by(fn {customer_id, completed} -> {-completed, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
