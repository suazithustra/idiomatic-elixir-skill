defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Only `"completed"` orders count toward spending and the top-customer
  ranking. The last order date considers every order, whatever its status.
  """

  @top_size 5

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
  Builds the report from a list of order rows.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` (ISO 8601 with offset) and `"status"`.

  Returns `{:ok, report}` or `{:error, reason}` for the first malformed row.
  The report is a map with two keys:

    * `:customers` - a map from customer ID to a map with `:totals`, a map
      from currency to the summed `Decimal` amount of completed orders, and
      `:last_order_at`, the latest `DateTime` among all of the customer's
      orders.
    * `:top_customers` - up to five `{customer_id, completed_count}` tuples,
      most completed orders first, ties broken by customer ID.
  """
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows) do
    parsed = Enum.map(rows, &parse_order/1)

    case Enum.find(parsed, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(parsed, fn {:ok, order} -> order end)}
      error -> error
    end
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount_text,
         "currency" => currency,
         "placed_at" => placed_at_text,
         "status" => status_text
       }) do
    with {:ok, amount} <- parse_amount(amount_text),
         {:ok, placed_at} <- parse_datetime(placed_at_text),
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

  defp parse_order(_row), do: {:error, :invalid_row}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:invalid_status, other}}

  defp summarize(orders) do
    by_customer = Enum.group_by(orders, & &1.customer_id)

    customers =
      Map.new(by_customer, fn {customer_id, customer_orders} ->
        {customer_id, customer_summary(customer_orders)}
      end)

    completed = Enum.filter(orders, &(&1.status == :completed))

    %{customers: customers, top_customers: top_customers(completed)}
  end

  defp customer_summary(customer_orders) do
    completed = Enum.filter(customer_orders, &(&1.status == :completed))

    %{
      totals: totals_by_currency(completed),
      last_order_at: last_order_at(customer_orders)
    }
  end

  defp totals_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, sum_amounts(currency_orders)}
    end)
  end

  defp sum_amounts(orders) do
    Enum.reduce(orders, Decimal.new(0), fn order, total ->
      Decimal.add(total, order.amount)
    end)
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(completed) do
    completed
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_size)
  end
end
