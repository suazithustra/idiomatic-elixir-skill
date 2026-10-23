defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer order report from rows produced by the CSV parser.

  Each row is a string-keyed map with the keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"`, and `"status"`. Rows are parsed into
  `Reports.Orders.Order` structs before any aggregation happens, so a malformed
  row is reported with the field that caused it.
  """

  defmodule Order do
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
  end

  @top_customer_count 5

  @type customer_summary :: %{
          totals_by_currency: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type error_reason :: {:missing_field, String.t()} | {:invalid_field, String.t()}

  @doc """
  Builds the report from a list of order rows.

  The report contains:

    * `:customers` - a map from customer ID to a summary with
      `:totals_by_currency` (the sum of completed order amounts per currency,
      empty when the customer has no completed orders) and `:last_order_on`
      (the date of the customer's most recent order of any status).
    * `:top_customers` - up to #{@top_customer_count} `{customer_id, count}`
      tuples, ordered by number of completed orders, most first. Ties are
      ordered by customer ID.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first malformed row.
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error_reason()}
  def build(rows) do
    case parse_orders(rows) do
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
    completed_by_customer = Enum.group_by(completed, & &1.customer_id)

    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(fn {customer_id, customer_orders} ->
      customer_completed = Map.get(completed_by_customer, customer_id, [])

      summary = %{
        totals_by_currency: totals_by_currency(customer_completed),
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

  defp parse_orders(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, orders} ->
      case parse_order(row) do
        {:ok, order} -> {:cont, {:ok, [order | orders]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_orders()
  end

  defp reverse_orders({:ok, orders}), do: {:ok, Enum.reverse(orders)}
  defp reverse_orders({:error, _reason} = error), do: error

  defp parse_order(row) do
    with {:ok, customer_id} <- string_field(row, "customer_id"),
         {:ok, amount} <- parsed_field(row, "amount", &parse_amount/1),
         {:ok, currency} <- parsed_field(row, "currency", &parse_currency/1),
         {:ok, placed_at} <- parsed_field(row, "placed_at", &parse_placed_at/1),
         {:ok, status} <- parsed_field(row, "status", &parse_status/1) do
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
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parsed_field(row, key, parser) do
    case string_field(row, key) do
      {:ok, text} -> parse_text(text, key, parser)
      {:error, _reason} = error -> error
    end
  end

  defp parse_text(text, key, parser) do
    case parser.(text) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> :error
      :error -> :error
    end
  end

  defp parse_currency(code) do
    if code =~ ~r/\A[A-Z]{3}\z/, do: {:ok, code}, else: :error
  end

  defp parse_placed_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> :error
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_status), do: :error
end
