defmodule Reports.Orders do
  @moduledoc """
  Builds a per-customer report from string-keyed order rows, as a CSV parser
  returns them.

  Only `completed` orders count toward money spent and the top-customer
  ranking. `last_order_on` is the date of the customer's most recent order
  of any status.
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

  @top_size 5

  @doc """
  Builds the report from a list of order rows.

  Returns `{:ok, report}`. `report.customers` maps each customer ID to
  `%{spent: %{currency => Decimal}, completed_count: integer, last_order_on: Date}`.
  `report.top_customers` lists up to five `{customer_id, completed_count}`
  pairs, most completed orders first, leaving out customers with none.

  Returns `{:error, reason}` for the first row that does not parse.
  """
  def build(rows) do
    with {:ok, orders} <- parse_rows(rows) do
      customers = summarize_customers(orders)
      report = %{customers: customers, top_customers: top_customers(customers)}

      {:ok, report}
    end
  end

  defp parse_rows(rows) do
    with {:ok, reversed} <- Enum.reduce_while(rows, {:ok, []}, &parse_next_row/2) do
      {:ok, Enum.reverse(reversed)}
    end
  end

  defp parse_next_row(row, {:ok, orders}) do
    case parse_row(row) do
      {:ok, order} -> {:cont, {:ok, [order | orders]}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp parse_row(%{
         "customer_id" => customer_id,
         "amount" => amount,
         "currency" => currency,
         "placed_at" => placed_at,
         "status" => status
       }) do
    with {:ok, amount} <- parse_amount(amount),
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

  defp parse_row(_row), do: {:error, :invalid_row}

  defp parse_amount(text) do
    case Decimal.parse(text) do
      {amount, ""} -> {:ok, amount}
      {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:invalid_field, "amount"}}
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

  defp summarize_customers(orders) do
    orders
    |> Enum.group_by(& &1.customer_id)
    |> Map.new(&summarize_customer/1)
  end

  defp summarize_customer({customer_id, orders}) do
    completed = Enum.filter(orders, &(&1.status == :completed))

    summary = %{
      spent: spent_by_currency(completed),
      completed_count: Enum.count(completed),
      last_order_on: last_order_on(orders)
    }

    {customer_id, summary}
  end

  defp spent_by_currency(completed) do
    completed
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(&sum_amounts/1)
  end

  defp sum_amounts({currency, amounts}) do
    {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
  end

  defp last_order_on(orders) do
    latest = Enum.max_by(orders, & &1.placed_at, DateTime)
    DateTime.to_date(latest.placed_at)
  end

  defp top_customers(customers) do
    customers
    |> Enum.map(fn {customer_id, summary} -> {customer_id, summary.completed_count} end)
    |> Enum.reject(fn {_customer_id, count} -> count == 0 end)
    |> Enum.sort_by(fn {_customer_id, count} -> count end, :desc)
    |> Enum.take(@top_size)
  end
end
