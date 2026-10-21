defmodule Reports.Orders do
  @moduledoc """
  Builds a customer report from orders parsed from a CSV file.

  Each order is a map with string keys `"customer_id"`, `"amount"`,
  `"currency"`, `"placed_at"` and `"status"`.
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

  @type customer_summary :: %{
          totals: %{String.t() => Decimal.t()},
          last_order_date: Date.t()
        }

  @type report :: %{
          customers: %{String.t() => customer_summary()},
          top_customers: [{String.t(), pos_integer()}]
        }

  @type error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @top_customer_count 5

  @doc """
  Builds the report from a list of orders.

  The report has two parts:

    * `:customers` - for each customer id, `:totals` (the sum of completed
      orders per currency) and `:last_order_date` (the UTC date of their most
      recent order of any status). A customer with no completed orders has
      empty `:totals`.
    * `:top_customers` - up to 5 `{customer_id, completed_count}` pairs, most
      completed orders first, ties broken by customer id.

  Returns `{:error, reason}` for the first order that is malformed.

  ## Examples

      iex> orders = [
      ...>   %{"customer_id" => "c1", "amount" => "10.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-01T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "4.50", "currency" => "EUR",
      ...>     "placed_at" => "2024-03-05T10:00:00Z", "status" => "completed"},
      ...>   %{"customer_id" => "c1", "amount" => "99.00", "currency" => "USD",
      ...>     "placed_at" => "2024-03-09T10:00:00Z", "status" => "refunded"}
      ...> ]
      iex> {:ok, report} = Reports.Orders.build(orders)
      iex> report.customers["c1"].last_order_date
      ~D[2024-03-09]
      iex> report.customers["c1"].totals
      %{"EUR" => Decimal.new("15.00")}
      iex> report.top_customers
      [{"c1", 2}]

      iex> Reports.Orders.build([%{"customer_id" => "c1"}])
      {:error, {:missing_field, "amount"}}
  """
  @spec build([map()]) :: {:ok, report()} | {:error, error()}
  def build(orders) when is_list(orders) do
    with {:ok, parsed} <- parse_orders(orders) do
      completed = Enum.filter(parsed, &(&1.status == :completed))

      {:ok,
       %{
         customers: customer_summaries(parsed, completed),
         top_customers: top_customers(completed)
       }}
    end
  end

  defp customer_summaries(orders, completed) do
    totals =
      Map.new(Enum.group_by(completed, & &1.customer_id), fn {id, group} ->
        {id, totals_by_currency(group)}
      end)

    Map.new(Enum.group_by(orders, & &1.customer_id), fn {id, group} ->
      summary = %{totals: Map.get(totals, id, %{}), last_order_date: last_order_date(group)}
      {id, summary}
    end)
  end

  defp totals_by_currency(orders) do
    orders
    |> Enum.group_by(& &1.currency, & &1.amount)
    |> Map.new(fn {currency, amounts} ->
      {currency, Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)}
    end)
  end

  defp last_order_date(orders) do
    orders
    |> Enum.map(& &1.placed_at)
    |> Enum.max(DateTime)
    |> DateTime.to_date()
  end

  defp top_customers(completed) do
    completed
    |> Enum.frequencies_by(& &1.customer_id)
    |> Enum.sort_by(fn {id, count} -> {-count, id} end)
    |> Enum.take(@top_customer_count)
  end

  defp parse_orders(orders) do
    orders
    |> Enum.reduce_while({:ok, []}, fn raw_order, {:ok, parsed} ->
      case parse_order(raw_order) do
        {:ok, order} -> {:cont, {:ok, [order | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_order(raw_order) do
    with {:ok, customer_id} <- string_field(raw_order, "customer_id"),
         {:ok, amount} <- parse_amount(raw_order),
         {:ok, currency} <- string_field(raw_order, "currency"),
         {:ok, placed_at} <- parse_placed_at(raw_order),
         {:ok, status} <- parse_status(raw_order) do
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

  defp string_field(raw_order, key) do
    case Map.fetch(raw_order, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_amount(raw_order) do
    with {:ok, text} <- string_field(raw_order, "amount") do
      case Decimal.parse(text) do
        {amount, ""} -> {:ok, amount}
        _other -> {:error, {:invalid_field, "amount"}}
      end
    end
  end

  defp parse_placed_at(raw_order) do
    with {:ok, text} <- string_field(raw_order, "placed_at") do
      case DateTime.from_iso8601(text) do
        {:ok, placed_at, _utc_offset} -> {:ok, placed_at}
        {:error, _reason} -> {:error, {:invalid_field, "placed_at"}}
      end
    end
  end

  defp parse_status(raw_order) do
    with {:ok, text} <- string_field(raw_order, "status") do
      case text do
        "completed" -> {:ok, :completed}
        "refunded" -> {:ok, :refunded}
        "pending" -> {:ok, :pending}
        _other -> {:error, {:invalid_field, "status"}}
      end
    end
  end
end
