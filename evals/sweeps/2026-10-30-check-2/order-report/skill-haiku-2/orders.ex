defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer summary and a top-customers ranking from order rows
  produced by the CSV parser.

  Spend is totalled per currency across completed orders only. The most recent
  order date counts orders of every status.
  """

  defmodule Order do
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

  @top_count 5

  @doc """
  Builds the report from string-keyed order rows.

  Returns `{:ok, report}` where `report` has:

    * `:customers` - one summary per customer
    * `:top_customers` - up to five summaries with at least one completed
      order, most completed orders first

  Each summary has `:customer_id`, `:spent` (a map from currency to the
  `Decimal` total of completed orders), `:last_order_at` (a `DateTime`), and
  `:completed_count`.

  Returns `{:error, reason}` for the first row that does not parse.
  """
  def build(rows) do
    with {:ok, orders} <- parse_all(rows) do
      {:ok, summarize(orders)}
    end
  end

  defp summarize(orders) do
    customers =
      orders
      |> Enum.group_by(& &1.customer_id)
      |> Enum.map(&summarize_customer/1)

    top_customers =
      customers
      |> Enum.filter(&(&1.completed_count > 0))
      |> Enum.sort_by(&{-&1.completed_count, &1.customer_id})
      |> Enum.take(@top_count)

    %{customers: customers, top_customers: top_customers}
  end

  defp summarize_customer({customer_id, orders}) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    spent =
      completed
      |> Enum.group_by(& &1.currency, & &1.amount)
      |> Map.new(&sum_currency/1)

    last_order_at =
      orders
      |> Enum.map(& &1.placed_at)
      |> Enum.max(DateTime)

    %{
      customer_id: customer_id,
      spent: spent,
      last_order_at: last_order_at,
      completed_count: Enum.count(completed)
    }
  end

  defp sum_currency({currency, amounts}) do
    {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
  end

  defp parse_all(rows) do
    Enum.reduce_while(rows, {:ok, []}, &collect_order/2)
  end

  defp collect_order(row, {:ok, orders}) do
    case parse_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
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

  defp parse_order(_row), do: {:error, :invalid_row}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp parse_datetime(text) do
    case DateTime.from_iso8601(text) do
      {:ok, placed_at, _offset} -> {:ok, placed_at}
      {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
    end
  end

  defp parse_status("completed"), do: {:ok, :completed}
  defp parse_status("refunded"), do: {:ok, :refunded}
  defp parse_status("pending"), do: {:ok, :pending}
  defp parse_status(_status), do: {:error, {:invalid_field, "status"}}
end
