defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into structs.

  Payloads are maps with string keys, as a JSON decoder produces them. Amounts
  stay integer minor units, and `"created"` becomes a `DateTime`. Payment events
  require `"customer_email"`.
  """

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @doc """
  Parses a decoded webhook payload into the struct for its event type.

  Returns `{:ok, event}` for `payment.succeeded`, `payment.failed`, and
  `refund.created`. Returns `{:error, {:unsupported_event, type}}` for any other
  type, and `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  when a field the event needs is absent or has the wrong type.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, refund} = Payments.Webhook.parse(payload)
      iex> refund.payment_id
      "pay_9"

      iex> payload = %{
      ...>   "id" => "evt_2",
      ...>   "type" => "charge.disputed",
      ...>   "created" => 1727000000,
      ...>   "data" => %{}
      ...> }
      iex> Payments.Webhook.parse(payload)
      {:error, {:unsupported_event, "charge.disputed"}}
  """
  def parse(payload) when is_map(payload) do
    with {:ok, type} <- required_field(payload, "type", &is_binary/1),
         {:ok, struct_module} <- event_struct(type),
         {:ok, event_id} <- required_field(payload, "id", &is_binary/1),
         {:ok, seconds} <- required_field(payload, "created", &is_integer/1),
         {:ok, occurred_at} <- from_unix(seconds),
         {:ok, data} <- required_field(payload, "data", &is_map/1),
         {:ok, fields} <- data_fields(struct_module, data) do
      header = %{event_id: event_id, occurred_at: occurred_at}
      {:ok, struct!(struct_module, Map.merge(header, fields))}
    end
  end

  defp event_struct("payment.succeeded"), do: {:ok, PaymentSucceeded}
  defp event_struct("payment.failed"), do: {:ok, PaymentFailed}
  defp event_struct("refund.created"), do: {:ok, RefundCreated}
  defp event_struct(type), do: {:error, {:unsupported_event, type}}

  defp data_fields(PaymentSucceeded, data), do: payment_fields(data)

  defp data_fields(PaymentFailed, data) do
    case payment_fields(data) do
      {:ok, fields} -> {:ok, Map.put(fields, :failure_reason, data["failure_reason"])}
      {:error, _reason} = error -> error
    end
  end

  defp data_fields(RefundCreated, data) do
    with {:ok, refund_id} <- required_field(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- required_field(data, "payment_id", &is_binary/1) do
      {:ok, %{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp payment_fields(data) do
    with {:ok, payment_id} <- required_field(data, "payment_id", &is_binary/1),
         {:ok, amount} <- required_field(data, "amount", &minor_units?/1),
         {:ok, currency} <- required_field(data, "currency", &is_binary/1),
         {:ok, customer_email} <- required_field(data, "customer_email", &is_binary/1) do
      fields = %{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, fields}
    end
  end

  defp required_field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp from_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp minor_units?(value), do: is_integer(value) and value >= 0
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` webhook event."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A `payment.failed` webhook event."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [
    :event_id,
    :occurred_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A `refund.created` webhook event."

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end
