defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with string keys: `"customer_id"`, `"amount"`
  (decimal string), `"currency"`, `"placed_at"` (ISO 8601 datetime) and
  `"status"` (`"completed"`, `"refunded"` or `"pending"`).
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Builds the report for a list of order maps.

  The report holds two entries:

    * `:customers` - for each customer id, `:totals` (the sum of completed
      order amounts per currency) and `:last_order_on` (the date of the
      latest order of any status, in UTC). A customer with no completed
      orders has empty `:totals`.
    * `:top_customers` - up to #{@top_customer_count} `{customer_id, completed_orders}`
      pairs, most completed orders first. Ties are broken by customer id.

  Returns `{:error, reason}` for the first order that has a missing or
  invalid field.

  ## Examples

      iex> Reports.Orders.build([])
      {:ok, %{customers: %{}, top_customers: []}}

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:missing_field, "amount"}}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, reason()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, orders} ->
      case Order.parse(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, orders} -> {customer_id, summarize_customer(orders)} end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %{
      totals: totals_by_currency(orders),
      last_order_on: DateTime.to_date(latest.placed_at)
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, orders} -> {currency, sum_amounts(orders)} end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), &Decimal.add(&1.amount, &2))
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp completed?(%Order{status: :completed}), do: true
  defp completed?(%Order{}), do: false
end

defmodule Reports.Orders.Order do
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

  @spec parse(map()) :: {:ok, t()} | {:error, Reports.Orders.reason()}
  def parse(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(status_text) do
      order = %__MODULE__{
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

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}
end
