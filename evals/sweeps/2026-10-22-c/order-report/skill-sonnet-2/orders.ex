defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Rows are string-keyed maps with the keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. They are parsed into
  `Reports.Orders.Order` structs before any aggregation, so a malformed row is
  reported with the field that is wrong instead of producing a wrong total.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  defmodule Order do
    @moduledoc false

    @enforce_keys [:customer_id, :amount, :currency, :placed_on, :status]
    defstruct [:customer_id, :amount, :currency, :placed_on, :status]

    @type status :: :completed | :refunded | :pending

    @type t :: %__MODULE__{
            customer_id: String.t(),
            amount: Decimal.t(),
            currency: String.t(),
            placed_on: Date.t(),
            status: status()
          }
  end

  defmodule CustomerSummary do
    @moduledoc """
    What the report knows about one customer.

    `totals` maps a currency to the sum of the customer's completed orders in
    that currency. `last_order_on` is the date of the customer's most recent
    order of any status.
    """

    @enforce_keys [:totals, :last_order_on]
    defstruct [:totals, :last_order_on]

    @type t :: %__MODULE__{
            totals: %{String.t() => Decimal.t()},
            last_order_on: Date.t()
          }
  end

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unknown_status, String.t()}

  @type report :: %{
          customers: %{String.t() => CustomerSummary.t()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report for a list of order rows.

  Returns `%{customers: customers, top_customers: top_customers}`, where
  `customers` maps each customer id to a `Reports.Orders.CustomerSummary` and
  `top_customers` lists up to #{@top_customer_count} `{customer_id, completed_orders}`
  pairs, most completed orders first. Ties are broken by customer id.

  Returns `{:error, reason}` for the first row that cannot be parsed.

  ## Examples

      iex> rows = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.00",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z",
      ...>     "status" => "pending"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.top_customers
      [{"c1", 1}]
      iex> report.customers["c1"].last_order_on
      ~D[2024-03-05]
      iex> Decimal.to_string(report.customers["c1"].totals["EUR"])
      "19.99"
  """
  @spec build([map()]) :: {:ok, report()} | {:error, reason()}
  def build(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- string_field(row, "placed_at"),
         {:ok, placed_on} <- parse_date(placed_at),
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

  defp parse_date(text) do
    case DateTime.from_iso8601(text) do
      {:ok, datetime, _utc_offset} -> {:ok, DateTime.to_date(datetime)}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    %{
      customers: summarize_customers(orders),
      top_customers: top_customers(orders)
    }
  end

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    %CustomerSummary{
      totals: totals_per_currency(orders),
      last_order_on: Enum.max_by(orders, & &1.placed_on, Date).placed_on
    }
  end

  defp totals_per_currency(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end
end
