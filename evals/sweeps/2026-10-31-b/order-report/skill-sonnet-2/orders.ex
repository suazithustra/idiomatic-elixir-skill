defmodule Reports.Orders.Order do
  @moduledoc """
  An order parsed from a string-keyed map, such as a row from a CSV parser.
  """

  @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
  defstruct [:customer_id, :amount, :currency, :placed_at, :status]

  @type status :: :completed | :refunded | :pending

  @type t :: %__MODULE__{
          customer_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          placed_at: DateTime.t(),
          status: status()
        }

  @type error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed map into an order.

  ## Examples

      iex> row = %{
      ...>   "customer_id" => "c1",
      ...>   "amount" => "19.99",
      ...>   "currency" => "EUR",
      ...>   "placed_at" => "2026-03-01T10:00:00Z",
      ...>   "status" => "completed"
      ...> }
      iex> {:ok, order} = Reports.Orders.Order.parse(row)
      iex> order.status
      :completed

      iex> Reports.Orders.Order.parse(%{})
      {:error, {:missing_field, "customer_id"}}
  """
  @spec parse(map()) :: {:ok, t()} | {:error, error()}
  def parse(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- amount_field(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- placed_at_field(row),
         {:ok, status} <- status_field(row) do
      {:ok,
       %__MODULE__{
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
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp amount_field(row) do
    with {:ok, text} <- string_field(row, "amount") do
      parse_amount(text)
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

  defp placed_at_field(row) do
    with {:ok, text} <- string_field(row, "placed_at") do
      parse_placed_at(text)
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

  defp status_field(row) do
    with {:ok, text} <- string_field(row, "status") do
      parse_status(text)
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}
end

defmodule Reports.Orders do
  @moduledoc """
  Builds a report from a list of orders.

  The report holds, for each customer, the total spent per currency across
  completed orders and the date of the most recent order, whatever its status.
  It also lists the customers with the most completed orders.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{customer_id :: String.t(), completed_orders :: pos_integer()}]
        }

  @doc """
  Builds the report from string-keyed order maps.

  `:customers` maps each customer id to its summary. `:top_customers` lists up
  to #{@top_customer_count} `{customer_id, completed_orders}` pairs, most
  completed orders first, with ties broken by customer id.

  Returns the first invalid order as `{:error, {index, reason}}`, where `index`
  is its position in the list, starting at 0.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-05T08:30:00Z",
      ...>     "status" => "pending"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2026-03-05]
      iex> report.top_customers
      [{"c1", 1}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {non_neg_integer(), Order.error()}}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      report = %{
        customers: customer_summaries(orders),
        top_customers: top_customers(orders)
      }

      {:ok, report}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case Order.parse(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | orders]}}

        {:error, reason} ->
          {:halt, {:error, {index, reason}}}
      end
    end)
  end

  defp customer_summaries(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize(customer_orders)}
    end)
  end

  defp summarize(customer_orders) do
    %{
      totals: totals_by_currency(customer_orders),
      last_order_on: last_order_on(customer_orders)
    }
  end

  defp totals_by_currency(customer_orders) do
    customer_orders
    |> completed()
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_on(customer_orders) do
    customer_orders
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

  defp completed(orders) do
    for %Order{status: :completed} = order <- orders, do: order
  end
end
