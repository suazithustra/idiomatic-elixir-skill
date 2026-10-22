defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency]
  defstruct [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A `payment.failed` event."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency]
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
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A `refund.created` event."

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads into event structs.

  Handled event types:

    * `"payment.succeeded"` -> `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` -> `Payments.Webhook.PaymentFailed`
    * `"refund.created"` -> `Payments.Webhook.RefundCreated`

  Any other type returns `{:error, {:unsupported_type, type}}`, so the caller
  can acknowledge the delivery without processing it.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:invalid_field, String.t()}
          | {:unsupported_type, String.t()}

  @spec parse(map()) :: {:ok, event()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created) do
      build(type, id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp build("payment.succeeded", id, occurred_at, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         event_id: id,
         occurred_at: occurred_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end

  defp build("payment.failed", id, occurred_at, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email"),
         {:ok, reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         event_id: id,
         occurred_at: occurred_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp build("refund.created", id, occurred_at, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id") do
      {:ok,
       %RefundCreated{
         event_id: id,
         occurred_at: occurred_at,
         refund_id: refund_id,
         payment_id: payment_id
       }}
    end
  end

  defp build(type, _id, _occurred_at, _data), do: {:error, {:unsupported_type, type}}

  defp to_datetime(unix) do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp fetch_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_amount(data) do
    case Map.fetch(data, "amount") do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _ -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp fetch_currency(data) do
    with {:ok, currency} <- fetch_string(data, "currency") do
      {:ok, String.upcase(currency)}
    end
  end
end
