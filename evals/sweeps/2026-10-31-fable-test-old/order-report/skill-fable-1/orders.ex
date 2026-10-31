defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from order rows produced by a CSV parser.

  Each row is a string-keyed map with the keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Rows are parsed into
  `Reports.Orders.Order` structs first, so a malformed row is reported with
  its position instead of producing a wrong report.
  """

  @top_customers_count 5

  @type row :: %{String.t() => String.t()}
  @type field_error :: {:missing_field, String.t()} | {:invalid_field, String.t()}
  @type error :: {:invalid_order, non_neg_integer(), field_error()}

  defmodule Order do
    @moduledoc "One parsed order row."

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

  defmodule CustomerSummary do
    @moduledoc """
    What the report knows about one customer.

    `totals` holds the amount spent on completed orders, keyed by currency
    code. `last_order_at` is the time of the most recent order of any status.
    """

    @enforce_keys [:completed_orders, :totals, :last_order_at]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            completed_orders: non_neg_integer(),
            totals: %{String.t() => Decimal.t()},
            last_order_at: DateTime.t()
          }
  end

  defmodule Report do
    @moduledoc """
    The finished report.

    `customers` maps each customer id to its summary. `top_customers` lists
    the ids of the customers with the most completed orders, most first, at
    most five of them. Ties keep the lower customer id first. Customers
    without a completed order are not listed.
    """

    @enforce_keys [:customers, :top_customers]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            customers: %{String.t() => Reports.Orders.CustomerSummary.t()},
            top_customers: [String.t()]
          }
  end

  @doc """
  Builds the report for a list of order rows.

  Returns `{:error, {:invalid_order, index, reason}}` for the first row that
  cannot be parsed, where `index` is the row's zero-based position in the
  list and `reason` names the field: `{:missing_field, key}` or
  `{:invalid_field, key}`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR",
      ...>     "placed_at" => "2024-05-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.00", "currency" => "EUR",
      ...>     "placed_at" => "2024-06-01T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.top_customers
      ["c1"]
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("19.99")}
      iex> report.customers["c1"].last_order_at
      ~U[2024-06-01 10:00:00Z]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:invalid_order, 0, {:missing_field, "amount"}}}
  """
  @spec build([row()]) :: {:ok, Report.t()} | {:error, error()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_orders(rows), do: parse_orders(rows, 0, [])

  defp parse_orders([], _index, orders), do: {:ok, Enum.reverse(orders)}

  defp parse_orders([row | rows], index, orders) do
    case parse_order(row) do
      {:ok, order} -> parse_orders(rows, index + 1, [order | orders])
      {:error, reason} -> {:error, {:invalid_order, index, reason}}
    end
  end

  defp parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency} <- string_field(row, "currency"),
         {:ok, placed_at_text} <- string_field(row, "placed_at"),
         {:ok, placed_at} <- parse_placed_at(placed_at_text),
         {:ok, status_text} <- string_field(row, "status"),
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

  defp string_field(row, key) do
    case Map.fetch(row, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
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

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %Report{customers: customers, top_customers: top_customers(customers)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)

    %CustomerSummary{
      completed_orders: length(completed),
      totals: totals_by_currency(completed),
      last_order_at: latest.placed_at
    }
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(customers) do
    customers
    |> Enum.reject(fn {_customer_id, summary} -> summary.completed_orders == 0 end)
    |> Enum.sort_by(fn {customer_id, summary} -> {-summary.completed_orders, customer_id} end)
    |> Enum.take(@top_customers_count)
    |> Enum.map(fn {customer_id, _summary} -> customer_id end)
  end
end
