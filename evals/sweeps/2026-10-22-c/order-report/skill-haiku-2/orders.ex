defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each customer gets the total of their completed orders per currency and the
  date of their most recent order of any status. The report also ranks the
  customers by number of completed orders.
  """

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

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          completed_count: non_neg_integer(),
          last_order_date: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Builds the report from order rows with string keys.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first row that does not parse.

  ## Examples

      iex> {:ok, report} = Reports.Orders.build([])
      iex> report
      %{customers: %{}, top_customers: []}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_orders(rows, []) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_orders([row | rows], acc) do
    case parse_order(row) do
      {:ok, order} -> parse_orders(rows, [order | acc])
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- amount_field(row),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- placed_at_field(row),
         {:ok, status} <- status_field(row) do
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
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _other} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(row) do
    with {:ok, text} <- string_field(row, "amount") do
      case Decimal.parse(text) do
        {amount, ""} -> {:ok, amount}
        {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
        :error -> {:error, {:invalid_field, "amount"}}
      end
    end
  end

  defp placed_at_field(row) do
    with {:ok, text} <- string_field(row, "placed_at") do
      case DateTime.from_iso8601(text) do
        {:ok, placed_at, _offset} -> {:ok, placed_at}
        {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
      end
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

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    %{
      totals: totals_by_currency(orders),
      completed_count: Enum.count(orders, &(&1.status == :completed)),
      last_order_date: last_order_date(orders)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp last_order_date(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    # Ties are broken by customer id so the ranking is the same on every run.
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
