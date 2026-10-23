defmodule Reports.Orders do
  @moduledoc """
  Builds a report from order rows produced by the CSV parser.

  Each row is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"`, and `"status"`. Rows are validated and parsed
  into `Reports.Orders.Order` structs before any aggregation happens.

  The report contains:

    * `:customers` - a map from customer ID to that customer's summary:
      * `:totals` - a map from currency code to the `Decimal` sum of the
        customer's completed orders in that currency
      * `:last_order_on` - the UTC `Date` of the customer's most recent order,
        whatever its status
    * `:top_customers` - up to five `{customer_id, completed_order_count}`
      tuples, most completed orders first, ties broken by customer ID
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

  @type row_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unknown_status, String.t()}

  @type error :: {:invalid_row, non_neg_integer(), row_error()}

  @doc """
  Builds the report from a list of CSV rows.

  Returns `{:error, {:invalid_row, index, reason}}` for the first row that
  cannot be parsed, where `index` is the zero-based position of the row.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(rows) do
    case parse_rows(rows) do
      {:ok, orders} -> {:ok, summarize(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp summarize(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    %{
      customers: customer_summaries(orders, completed),
      top_customers: top_customers(completed)
    }
  end

  defp customer_summaries(orders, completed) do
    totals_by_customer =
      completed
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, totals_by_currency(customer_orders)}
      end)

    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      summary = %{
        totals: Map.get(totals_by_customer, customer_id, %{}),
        last_order_on: last_order_on(customer_orders)
      }

      {customer_id, summary}
    end)
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.reduce(amounts, &Decimal.add/2)} end)
  end

  defp last_order_on(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(completed) do
    completed
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} -> {-count, customer_id} end)
    |> Enum.take(@top_customer_count)
  end

  defp parse_rows(rows) do
    parsed =
      rows
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, &parse_row/2)

    case parsed do
      {:ok, orders} -> {:ok, Enum.reverse(orders)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_row({row, index}, {:ok, orders}) do
    case Order.parse(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, reason} -> {:halt, {:error, {:invalid_row, index, reason}}}
    end
  end
end

defmodule Reports.Orders.Order do
  @moduledoc """
  A single order, parsed from a string-keyed CSV row.
  """

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

  @doc """
  Parses a CSV row into an order.

  Returns `{:error, {:missing_field, key}}` when a key is absent or blank,
  `{:error, {:invalid_field, key}}` when a value cannot be parsed, and
  `{:error, {:unknown_status, status}}` for a status other than
  `"completed"`, `"refunded"`, or `"pending"`.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, Reports.Orders.row_error()}
  def parse(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount_text} <- string_field(row, "amount"),
         {:ok, amount} <- parse_amount(amount_text),
         {:ok, currency_text} <- string_field(row, "currency"),
         {:ok, currency} <- parse_currency(currency_text),
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
      {:ok, value} when is_binary(value) -> non_blank(String.trim(value), key)
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp non_blank("", key), do: {:error, {:missing_field, key}}
  defp non_blank(value, _key), do: {:ok, value}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_currency(text) do
    if text =~ ~r/\A[A-Z]{3}\z/ do
      {:ok, text}
    else
      {:error, {:invalid_field, "currency"}}
    end
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}
end
