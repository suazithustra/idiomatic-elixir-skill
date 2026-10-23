defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders produced by the CSV parser.

  Each order is a map with string keys:

    * `"customer_id"` - customer identifier
    * `"amount"` - decimal string, e.g. `"19.99"`
    * `"currency"` - ISO currency code, e.g. `"EUR"`
    * `"placed_at"` - ISO 8601 datetime string
    * `"status"` - `"completed"`, `"refunded"` or `"pending"`

  The report has the shape:

      %{
        customers: %{
          "c1" => %{
            totals: %{"EUR" => Decimal.new("39.98")},
            last_order_on: ~D[2024-03-01]
          }
        },
        top_customers: [{"c1", 2}, ...]
      }

  `totals` only counts completed orders. `last_order_on` is the date of the
  customer's most recent order of any status. `top_customers` lists up to
  five customers by number of completed orders, ties broken by customer id.
  """

  @top_count 5
  @statuses %{"completed" => :completed, "refunded" => :refunded, "pending" => :pending}

  @type customer_id :: String.t()
  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }
  @type report :: %{
          customers: %{customer_id => customer_summary},
          top_customers: [{customer_id, pos_integer}]
        }

  @doc """
  Builds the report, or returns the first order that could not be parsed.
  """
  @spec build([map]) :: {:ok, report} | {:error, {:invalid_order, map, atom}}
  def build(rows) when is_list(rows) do
    with {:ok, orders} <- parse_all(rows) do
      {:ok, %{customers: summarize_customers(orders), top_customers: top_customers(orders)}}
    end
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id,
       %{
         totals: totals_by_currency(customer_orders),
         last_order_on: last_order_on(customer_orders)
       }}
    end)
  end

  defp totals_by_currency(orders) do
    for %{status: :completed} = order <- orders, reduce: %{} do
      totals -> Map.update(totals, order.currency, order.amount, &Decimal.add(&1, order.amount))
    end
  end

  defp last_order_on(orders) do
    orders
    |> Enum.max_by(& &1.placed_at, DateTime)
    |> Map.fetch!(:placed_at)
    |> DateTime.to_date()
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_count)
  end

  ## Parsing

  defp parse_all(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case parse(row) do
        {:ok, order} -> {:cont, {:ok, [order | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_order, row, reason}}}
      end
    end)
  end

  defp parse(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       })
       when customer_id != "" do
    with {:ok, amount} <- parse_amount(amount),
         {:ok, placed_at} <- parse_datetime(placed_at),
         {:ok, status} <- parse_status(status) do
      {:ok,
       %{
         customer_id: customer_id,
         amount: amount,
         currency: String.upcase(currency),
         placed_at: placed_at,
         status: status
       }}
    end
  end

  defp parse(_row), do: {:error, :missing_fields}

  defp parse_amount(amount) when is_binary(amount) do
    case Decimal.parse(String.trim(amount)) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, :invalid_amount}
    end
  end

  defp parse_amount(_amount), do: {:error, :invalid_amount}

  # Datetimes without an offset are assumed to be UTC.
  defp parse_datetime(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(string) do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, _reason} -> {:error, :invalid_placed_at}
        end

      {:error, _reason} ->
        {:error, :invalid_placed_at}
    end
  end

  defp parse_datetime(_string), do: {:error, :invalid_placed_at}

  defp parse_status(status) do
    case Map.fetch(@statuses, status) do
      {:ok, status} -> {:ok, status}
      :error -> {:error, :invalid_status}
    end
  end
end
