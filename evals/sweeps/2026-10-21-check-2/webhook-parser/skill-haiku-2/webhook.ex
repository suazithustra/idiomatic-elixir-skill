defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into structs.

  Supported event types are `payment.succeeded`, `payment.failed`, and
  `refund.created`. Amounts are integer minor units (for example, cents).
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a decoded webhook payload with string keys.

  Returns `{:ok, event}` or `{:error, reason}`. Reasons are
  `{:missing_field, key}`, `{:invalid_field, key}`,
  `{:unsupported_event, type}`, or `:invalid_payload`.
  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, event_id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, created} <- typed_field(payload, "created", &is_integer/1),
         {:ok, occurred_at} <- to_datetime(created),
         {:ok, data} <- typed_field(payload, "data", &is_map/1) do
      build(type, %{event_id: event_id, occurred_at: occurred_at}, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp build("payment.succeeded", meta, data) do
    case payment_fields(data) do
      {:ok, payment} -> {:ok, struct!(PaymentSucceeded, Map.merge(meta, payment))}
      {:error, _reason} = error -> error
    end
  end

  defp build("payment.failed", meta, data) do
    with {:ok, payment} <- payment_fields(data),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      fields = payment |> Map.put(:failure_reason, failure_reason) |> Map.merge(meta)
      {:ok, struct!(PaymentFailed, fields)}
    end
  end

  defp build("refund.created", meta, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok,
       struct!(RefundCreated, Map.merge(meta, %{refund_id: refund_id, payment_id: payment_id}))}
    end
  end

  defp build(type, _meta, _data), do: {:error, {:unsupported_event, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- typed_field(data, "amount", &minor_units?/1),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp to_datetime(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp string_field(data, key), do: typed_field(data, key, &is_binary/1)

  defp optional_string_field(data, key) do
    case data[key] do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp typed_field(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp minor_units?(value), do: is_integer(value) and value >= 0
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event. `amount` is in minor units."

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
  @moduledoc "A `payment.failed` event. `amount` is in minor units."

  @enforce_keys [
    :event_id,
    :occurred_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]
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
