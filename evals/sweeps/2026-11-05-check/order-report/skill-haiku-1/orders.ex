defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from orders read out of a CSV file.

  Each input order is a map with string keys: `"customer_id"`, `"amount"`
  (a decimal string such as `"19.99"`), `"currency"`, `"placed_at"` (an ISO 8601
  datetime with an offset) and `"status"` (`"completed"`, `"refunded"` or
  `"pending"`).

  Spending totals and the top-customer ranking count completed orders only.
  The last order date counts every order, whatever its status.
  """

  @top_count 5

  defmodule Order do
    @moduledoc false
    @enforce_keys [:customer_id, :amount, :currency, :placed_at, :status]
    defstruct @enforce_keys
  end

  @typedoc """
  `:spent` maps each currency to the total of the customer's completed orders
  in it. `:last_order_at` is the latest `placed_at` across all their orders.
  """
  @type customer_summary :: %{
          spent: %{String.t() => Decimal.t()},
          last_order_at: DateTime.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report for `orders`.

  On success `report.customers` maps each customer ID to a `t:customer_summary/0`,
  and `report.top_customers` lists up to five `{customer_id, completed_count}`
  tuples, most completed orders first, with ties broken by customer ID.

  Returns `{:error, reason}` for the first order that cannot be read. The reason
  names the field, such as `{:invalid_field, "amount"}`.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, term()}
  def build(orders) do
    with {:ok, parsed} <- parse_orders(orders) do
      {:ok, summarize(parsed)}
    end
  end

  defp parse_orders(orders) do
    Enum.reduce_while(orders, {:ok, []}, fn order, {:ok, parsed} ->
      case parse_order(order) do
        {:ok, parsed_order} -> {:cont, {:ok, [parsed_order | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_datetime(placed_at),
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

  defp parse_order(_order), do: {:error, :invalid_order}

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
  defp parse_status(_other), do: {:error, {:invalid_field, "status"}}

  defp summarize(orders) do
    %{
      customers: customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, orders} -> {customer_id, customer_summary(orders)} end)
  end

  defp customer_summary(orders) do
    %{
      spent: spent_by_currency(orders),
      last_order_at: last_order_at(orders)
    }
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_at(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  defp completed?(order), do: order.status == :completed
end
