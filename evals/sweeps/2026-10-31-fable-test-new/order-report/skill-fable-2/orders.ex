defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer spending report from parsed CSV order rows.

  Each row is a map with string keys `"customer_id"`, `"amount"` (a decimal
  string such as `"19.99"`), `"currency"` (`"EUR"`, `"USD"`, ...), `"placed_at"`
  (an ISO 8601 datetime) and `"status"` (`"completed"`, `"refunded"` or
  `"pending"`).

  Amounts are kept as `Decimal` values and summed per currency without
  conversion. The date of a customer's most recent order is the UTC calendar
  date of that order's `placed_at`, whatever its status.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.01", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-02T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "100.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "refunded"},
      ...>   %{"customer_id" => "c2", "amount" => "7.50", "currency" => "USD",
      ...>     "placed_at" => "2024-03-03T10:00:00Z", "status" => "completed"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.top_customers
      [{"c1", 2}, {"c2", 1}]
      iex> Decimal.to_string(report.customers["c1"].spent["EUR"])
      "25.00"
      iex> report.customers["c1"].spent["USD"]
      nil
      iex> report.customers["c1"].last_order_date
      ~D[2024-03-05]
      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_row, 1, {:missing_field, "amount"}}}
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

  defmodule Customer do
    @moduledoc """
    One customer's totals: `spent` maps a currency code to the sum of that
    customer's completed orders in it, and `last_order_date` is the UTC date of
    their most recent order in any status.
    """

    @enforce_keys [:spent, :last_order_date]
    defstruct @enforce_keys

    @type t :: %__MODULE__{spent: %{String.t() => Decimal.t()}, last_order_date: Date.t()}
  end

  defmodule Report do
    @moduledoc """
    The report: `customers` maps a customer id to its `Reports.Orders.Customer`,
    and `top_customers` lists `{customer_id, completed_order_count}` pairs for
    the five customers with the most completed orders, most first.
    """

    @enforce_keys [:customers, :top_customers]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            customers: %{String.t() => Customer.t()},
            top_customers: [{String.t(), pos_integer()}]
          }
  end

  @top_customers_count 5

  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}
  @type error :: {:invalid_row, pos_integer(), field_error()}

  @doc """
  Builds the report from a list of order rows.

  Returns `{:error, {:invalid_row, row_number, reason}}` for the first row that
  lacks a required field or holds one that does not parse. Rows are numbered
  from 1.
  """
  @spec build([map()]) :: {:ok, Report.t()} | {:error, error()}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows), do: parse_orders(Enum.with_index(rows, 1), [])

  defp parse_orders([], orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([{row, row_number} | rest], orders) do
    case parse_order(row) do
      {:ok, order} ->
        parse_orders(rest, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_row, row_number, reason}}
    end
  end

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parsed_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at} <- parsed_field(row, "placed_at", &parse_placed_at/1),
         {:ok, status} <- parsed_field(row, "status", &parse_status/1) do
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

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parsed_field(row, key, parse) do
    with {:ok, text} <- string_field(row, key), do: parse.(text)
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

  defp summarize(orders) do
    %Report{customers: customers(orders), top_customers: top_customers(orders)}
  end

  defp customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      {customer_id, summarize_customer(customer_orders)}
    end)
  end

  defp summarize_customer(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %Customer{
      spent: spent_by_currency(orders),
      last_order_date: DateTime.to_date(latest.placed_at)
    }
  end

  defp spent_by_currency(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, sum_amounts(amounts)} end)
  end

  defp sum_amounts(amounts), do: Enum.reduce(amounts, &Decimal.add/2)

  defp top_customers(orders) do
    orders
    |> Enum.filter(&completed?/1)
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customers_count)
  end

  defp completed?(%Order{status: :completed}), do: true
  defp completed?(%Order{}), do: false
end
