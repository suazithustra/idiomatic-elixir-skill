defmodule Reports.Orders do
  @moduledoc """
  Builds a report from orders parsed out of a CSV file.

  Rows are string-keyed maps. They are parsed into `Reports.Orders.Order`
  structs first, so the report code works on validated data.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

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
  Builds the report for a list of orders.

  Per customer, `:totals` holds the amount spent per currency across completed
  orders, and `:last_order_at` the time of their most recent order of any
  status. `:top_customers` lists up to #{@top_customer_count} `{customer_id,
  completed_order_count}` pairs, most orders first, ties broken by customer id.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, where `index` is its position in `rows`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-03T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "9.00", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-04T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"].totals["EUR"]
      Decimal.new("25.00")
      iex> report.customers["c1"].last_order_at
      ~U[2024-05-04 10:00:00Z]
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, report()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      report = %{
        customers: summarize_customers(orders),
        top_customers: top_customers(orders)
      }

      {:ok, report}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} ->
          {:cont, {:ok, [order | orders]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_order, index, reason}}}
      end
    end)
  end

  defp parse_order(
         %{
           "customer_id" => customer_id,
           "amount" => amount,
           "currency" => currency,
           "placed_at" => placed_at,
           "status" => status
         } = _row
       ) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_placed_at(placed_at),
         {:ok, status} <- parse_status(status) do
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

  defp parse_order(_row), do: {:error, :missing_field}

  defp parse_amount(text) when is_binary(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_text), do: {:error, {:invalid_field, "amount"}}

  defp parse_placed_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_at(_text), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    last_order_at = Enum.max_by(orders, & &1.placed_at, DateTime).placed_at

    %{totals: totals_per_currency(completed(orders)), last_order_at: last_order_at}
  end

  defp totals_per_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
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
