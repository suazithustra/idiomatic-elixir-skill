defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Orders are validated and turned
  into structs before any totals are computed.
  """

  alias Reports.Orders.CustomerSummary
  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_id :: String.t()

  @type report :: %{
          customers: %{customer_id() => CustomerSummary.t()},
          top_customers: [{customer_id(), non_neg_integer()}]
        }

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unknown_status, String.t()}

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

  defmodule CustomerSummary do
    @moduledoc """
    One customer's figures: `spent` is the total of completed orders per
    currency, `completed_count` the number of completed orders, and
    `last_order_on` the date of the latest order of any status.
    """

    @enforce_keys [:spent, :completed_count, :last_order_on]
    defstruct [:spent, :completed_count, :last_order_on]

    @type t :: %__MODULE__{
            spent: %{String.t() => Decimal.t()},
            completed_count: non_neg_integer(),
            last_order_on: Date.t()
          }
  end

  @doc """
  Builds the report from a list of order maps.

  `:customers` maps each customer id to a `CustomerSummary`. `:top_customers`
  lists up to five `{customer_id, completed_count}` pairs, most completed
  orders first, with ties broken by customer id. Customers without completed
  orders are left out of it.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order that
  fails validation, where `index` is its position in the list.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.top_customers
      [{"c1", 1}]
      iex> report.customers["c1"].last_order_on
      ~D[2026-03-01]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_order, 0, {:missing_field, "amount"}}}
  """
  @spec build([map()]) ::
          {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), reason()}}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      customers = summarize_customers(orders)

      {:ok, %{customers: customers, top_customers: top_customers(customers)}}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &accumulate_order/2)
  end

  defp accumulate_order({row, index}, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} ->
        {:cont, {:ok, [order | orders]}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_order, index, reason}}}
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- string_field(row, "placed_at"),
         {:ok, placed_on} <- parse_placed_on(placed_at),
         {:ok, status_text} <- string_field(row, "status"),
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

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
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

  defp parse_placed_on(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %CustomerSummary{
      spent: spent_per_currency(completed),
      completed_count: length(completed),
      last_order_on: Enum.max_by(orders, & &1.placed_on, Date).placed_on
    }
  end

  defp spent_per_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.reject(fn {_customer_id, count} -> count == 0 end)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
