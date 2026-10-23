defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by the CSV parser.

  Only `"completed"` orders count toward spending and the completed-order
  ranking. Every order, whatever its status, counts toward the date of the
  customer's most recent order.
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

  @top_count 5

  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from order rows.

  `:customers` maps each customer ID to `:spent`, the total of that customer's
  completed orders per currency, and `:last_order_on`, the date of their most
  recent order of any status.

  `:top_customers` lists up to five `{customer_id, count}` pairs, where `count`
  is the number of completed orders, highest first. Ties are broken by customer ID.

  Returns `{:error, reason}` for the first row with a missing or invalid field.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    parsed = Enum.map(rows, &parse_order/1)

    case Enum.find(parsed, &match?({:error, _reason}, &1)) do
      nil -> {:ok, Enum.map(parsed, fn {:ok, order} -> order end)}
      error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_datetime(text),
         {:ok, text} <- string_field(row, "status"),
         {:ok, status} <- parse_status(text) do
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
  defp parse_status(_text), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, customer_summary(customer_orders)}
      end)

    %{
      customers: customers,
      top_customers: top_customers(Enum.filter(orders, &completed?/1))
    }
  end

  defp customer_summary(customer_orders) do
    %{
      spent: spent_by_currency(Enum.filter(customer_orders, &completed?/1)),
      last_order_on: last_order_date(customer_orders)
    }
  end

  defp spent_by_currency(completed_orders) do
    completed_orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_date(customer_orders) do
    customer_orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(completed_orders) do
    completed_orders
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(order), do: order.status == :completed
end
