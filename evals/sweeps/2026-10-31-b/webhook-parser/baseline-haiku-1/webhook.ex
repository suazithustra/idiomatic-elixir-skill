defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload (a map with string keys) into a typed struct.

  Supported event types:

    * `"payment.succeeded"` -> `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` -> `Payments.Webhook.PaymentFailed`
    * `"refund.created"` -> `Payments.Webhook.RefundCreated`

  Amounts are integers in minor units (for example, cents). Currency codes are
  stored upper-cased (ISO 4217, for example `"EUR"`).
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a webhook payload.

  Returns `{:ok, event}` or `{:error, reason}`. Reasons:

    * `:invalid_envelope` - `id`, `type`, `created` or `data` is missing or has the wrong shape
    * `:invalid_timestamp` - `created` is not a valid Unix timestamp in seconds
    * `:invalid_data` - the `data` map is missing required fields for the event type
    * `{:unsupported_type, type}` - the event type is not one this module handles
  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created) do
      build(type, id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_envelope}

  defp build("payment.succeeded", id, occurred_at, data) do
    with {:ok, fields} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, Map.merge(fields, %{event_id: id, occurred_at: occurred_at}))}
    end
  end

  defp build("payment.failed", id, occurred_at, data) do
    with {:ok, fields} <- payment_fields(data) do
      extra = %{event_id: id, occurred_at: occurred_at, failure_reason: data["failure_reason"]}
      {:ok, struct!(PaymentFailed, Map.merge(fields, extra))}
    end
  end

  defp build("refund.created", id, occurred_at, %{"refund_id" => refund_id, "payment_id" => payment_id})
       when is_binary(refund_id) and is_binary(payment_id) do
    fields = %{event_id: id, occurred_at: occurred_at, refund_id: refund_id, payment_id: payment_id}
    {:ok, struct!(RefundCreated, fields)}
  end

  defp build("refund.created", _id, _occurred_at, _data), do: {:error, :invalid_data}

  defp build(type, _id, _occurred_at, _data), do: {:error, {:unsupported_type, type}}

  defp payment_fields(%{"payment_id" => payment_id, "amount" => amount, "currency" => currency} = data)
       when is_binary(payment_id) and is_integer(amount) and amount >= 0 and is_binary(currency) do
    {:ok,
     %{
       payment_id: payment_id,
       amount: amount,
       currency: String.upcase(currency),
       customer_email: data["customer_email"]
     }}
  end

  defp payment_fields(_data), do: {:error, :invalid_data}

  defp to_datetime(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp to_datetime(_seconds), do: {:error, :invalid_timestamp}
end

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
