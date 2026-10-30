defmodule Reports.Orders.Order do
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

defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed out of a CSV file.

  Each order is a map with the string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`. Orders are validated and turned
  into `Reports.Orders.Order` structs before any totals are computed.
  """

  alias Reports.Orders.Order

  @top_customer_count 5

  @type customer_report :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_on: Date.t()
        }

  @type t :: %{
          customers: %{String.t() => customer_report()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @doc """
  Builds the report from a list of string-keyed order maps.

  The report has two parts:

    * `:customers` - for each customer, `:totals` (the amount spent per
      currency across completed orders) and `:last_order_on` (the date of
      their most recent order, whatever its status).
    * `:top_customers` - up to five `{customer_id, completed_orders}` pairs,
      most completed orders first. Ties are broken by customer id.

  A customer with no completed orders has empty `:totals` and is left out of
  `:top_customers`.

  Returns `{:error, {:invalid_order, index, reason}}` for the first order that
  fails validation, where `index` is its position in the list, starting at 0.

  ## Examples

      iex> orders = [
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "19.99",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-01T10:00:00Z",
      ...>     "status" => "completed"
      ...>   },
      ...>   %{
      ...>     "customer_id" => "c1",
      ...>     "amount" => "5.01",
      ...>     "currency" => "EUR",
      ...>     "placed_at" => "2026-03-04T10:00:00Z",
      ...>     "status" => "completed"
      ...>   }
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_on
      ~D[2026-03-04]
      iex> Decimal.to_string(report.customers["c1"].totals["EUR"])
      "25.00"
      iex> report.top_customers
      [{"c1", 2}]
  """
  @spec build([map()]) :: {:ok, t()} | {:error, {:invalid_order, non_neg_integer(), term()}}
  def build(rows) do
    with {:ok, orders} <- parse_orders(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp parse_orders(rows) do
    rows
    |> Enum.with_index()
    |> parse_orders([])
  end

  defp parse_orders([], orders), do: {:ok, orders}

  defp parse_orders([{row, index} | rest], orders) do
    case parse_order(row) do
      {:ok, order} ->
        parse_orders(rest, [order | orders])

      {:error, reason} ->
        {:error, {:invalid_order, index, reason}}
    end
  end

  defp parse_order(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, customer_id} <- parse_customer_id(customer_id),
         {:ok, amount} <- parse_amount(amount),
         {:ok, currency} <- parse_currency(currency),
         {:ok, placed_at} <- parse_placed_at(placed_at),
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

  defp parse_order(row) when is_map(row) do
    required = ["customer_id", "amount", "currency", "placed_at", "status"]
    {:error, {:missing_field, Enum.find(required, &(not Map.has_key?(row, &1)))}}
  end

  defp parse_order(_row), do: {:error, :not_a_map}

  defp parse_customer_id(customer_id) when is_binary(customer_id) and customer_id != "" do
    {:ok, customer_id}
  end

  defp parse_customer_id(_customer_id), do: {:error, {:invalid_field, "customer_id"}}

  defp parse_amount(text) when is_binary(text) do
    case Decimal.parse(text) do
      {amount, ""} ->
        {:ok, amount}

      {_amount, _rest} ->
        {:error, {:invalid_field, "amount"}}

      :error ->
        {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_amount(_amount), do: {:error, {:invalid_field, "amount"}}

  defp parse_currency(currency) when is_binary(currency) and currency != "" do
    {:ok, currency}
  end

  defp parse_currency(_currency), do: {:error, {:invalid_field, "currency"}}

  defp parse_placed_at(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _utc_offset} ->
        {:ok, placed_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_placed_at(_placed_at), do: {:error, {:invalid_field, "placed_at"}}

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(other), do: {:error, {:unknown_status, other}}

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Map.new(fn {customer_id, customer_orders} ->
        {customer_id, summarize_customer(customer_orders)}
      end)

    %{customers: customers, top_customers: top_customers(orders)}
  end

  defp summarize_customer(orders) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    last_order_at =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{totals: totals_by_currency(completed), last_order_on: DateTime.to_date(last_order_at)}
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency)
    |> Map.new(fn {currency, currency_orders} ->
      {currency, Enum.reduce(currency_orders, Decimal.new(0), &Decimal.add(&1.amount, &2))}
    end)
  end

  defp top_customers(orders) do
    orders
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {customer_id, count} ->
      {-count, customer_id}
    end)
    |> Enum.take(@top_customer_count)
  end
end
