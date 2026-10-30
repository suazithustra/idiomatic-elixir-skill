defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into a typed event.

  Payloads are maps with string keys, as produced by a JSON decoder. Amounts
  are integers in minor units (for example, cents for EUR).

  Supported event types:

    * `"payment.succeeded"` -> `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` -> `Payments.Webhook.PaymentFailed`
    * `"refund.created"` -> `Payments.Webhook.RefundCreated`

  Any other type returns `{:error, {:unsupported_type, type}}` so the caller
  can acknowledge the webhook and skip it.
  """

  defmodule PaymentSucceeded do
    @moduledoc "A payment was captured successfully."
    @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency]
    defstruct [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  end

  defmodule PaymentFailed do
    @moduledoc "A payment attempt failed."
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
  end

  defmodule RefundCreated do
    @moduledoc "A refund was created against a payment."
    @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
    defstruct [:event_id, :occurred_at, :refund_id, :payment_id]
  end

  @doc """
  Parses a decoded webhook payload into one of the event structs above.
  """
  @spec parse(map()) :: {:ok, struct()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- DateTime.from_unix(created) do
      build(type, id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :malformed_payload}

  defp build("payment.succeeded", id, occurred_at, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data) do
      {:ok,
       %PaymentSucceeded{
         event_id: id,
         occurred_at: occurred_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: optional_string(data, "customer_email")
       }}
    end
  end

  defp build("payment.failed", id, occurred_at, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data) do
      {:ok,
       %PaymentFailed{
         event_id: id,
         occurred_at: occurred_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: optional_string(data, "customer_email"),
         failure_reason: optional_string(data, "failure_reason")
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

  defp fetch_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_amount(data) do
    case Map.get(data, "amount") do
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _ -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp fetch_currency(data) do
    case Map.get(data, "currency") do
      code when is_binary(code) and byte_size(code) == 3 -> {:ok, String.upcase(code)}
      _ -> {:error, {:invalid_field, "currency"}}
    end
  end

  defp optional_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end
