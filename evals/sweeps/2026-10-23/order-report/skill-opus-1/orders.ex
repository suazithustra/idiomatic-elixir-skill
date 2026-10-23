defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from order rows produced by a CSV parser.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Every row is validated
  before anything is summed, so one malformed row fails the whole report
  instead of producing wrong totals.
  """

  defmodule InvalidRowError do
    @moduledoc """
    Returned when an order row is missing a field or holds a value that
    cannot be parsed.

    `:index` is the position of the row in the input list, starting at 0.
    `:reason` is `{:missing_field, key}` or `{:invalid_field, key}`.
    """

    defexception [:index, :reason]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            reason: {:missing_field, String.t()} | {:invalid_field, String.t()}
          }

    @impl true
    def message(%__MODULE__{index: index, reason: {:missing_field, key}}) do
      "order row #{index} is missing the field #{inspect(key)}"
    end

    def message(%__MODULE__{index: index, reason: {:invalid_field, key}}) do
      "order row #{index} has an invalid value in the field #{inspect(key)}"
    end
  end

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

  @type customer_id :: String.t()
  @type currency :: String.t()

  @type customer_summary :: %{
          totals: %{currency() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{customer_id() => customer_summary()},
          top_customers: [{customer_id(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of order rows.

  The report has two keys:

    * `:customers` - a map from customer ID to a summary holding `:totals`,
      the amount spent per currency across completed orders, and
      `:last_order_on`, the UTC date of the customer's most recent order of
      any status. A customer with no completed orders has empty totals.

    * `:top_customers` - up to #{@top_customer_count} `{customer_id, count}`
      tuples for the customers with the most completed orders, most first.
      Customers with the same count are ordered by customer ID.

  `"amount"` must be a non-negative decimal such as `"19.99"`, `"currency"`
  a three-letter upper-case code, `"placed_at"` an ISO 8601 datetime with a
  UTC offset, and `"status"` one of `"completed"`, `"refunded"` or
  `"pending"`. The first row that breaks these rules is returned as an
  `InvalidRowError`.

  ## Examples

      iex> rows = [
      ...>   %{"customer_id" => "c1", "amount" => "19.99", "currency" => "EUR", "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "5.00", "currency" => "EUR", "placed_at" => "2024-03-04T09:30:00Z", "status" => "refunded"},
      ...>   %{"customer_id" => "c2", "amount" => "12.50", "currency" => "USD", "placed_at" => "2024-02-11T16:45:00Z", "status" => "pending"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(rows)
      iex> report.customers["c1"]
      %{totals: %{"EUR" => Decimal.new("19.99")}, last_order_on: ~D[2024-03-04]}
      iex> report.customers["c2"]
      %{totals: %{}, last_order_on: ~D[2024-02-11]}
      iex> report.top_customers
      [{"c1", 1}]

      iex> Reports.Orders.build([%{"customer_id" => "c1", "amount" => "19.99"}])
      {:error, %Reports.Orders.InvalidRowError{index: 0, reason: {:missing_field, "currency"}}}

  """
  @spec build([map()]) :: {:ok, report()} | {:error, InvalidRowError.t()}
  def build(rows) when is_list(rows) do
    case parse_orders(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _error} = error -> error
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, reason} -> {:halt, {:error, %InvalidRowError{index: index, reason: reason}}}
      end
    end)
  end

  defp parse_order(row) when is_map(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency_text} <- string_field(row, "currency"),
         {:ok, currency} <- parse_currency(currency_text),
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
      {:ok, ""} -> {:error, {:missing_field, key}}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  # Decimal.parse/1 also accepts "NaN", "Infinity", exponents and signs,
  # none of which is a valid order amount.
  defp parse_amount(text) do
    if Regex.match?(~r/\A\d+(\.\d+)?\z/, text) do
      {:ok, Decimal.new(text)}
    else
      {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_currency(text) do
    if Regex.match?(~r/\A[A-Z]{3}\z/, text) do
      {:ok, text}
    else
      {:error, {:invalid_field, "currency"}}
    end
  end

  # A datetime without an offset cannot be ordered against the others, so it
  # is rejected rather than assumed to be UTC.
  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_status), do: {:error, {:invalid_field, "status"}}

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
    %{
      totals: completed_totals(orders),
      last_order_on: last_order_on(orders)
    }
  end

  defp completed_totals(orders) do
    orders
    |> completed()
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
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
