defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `data` holds one of the body structs."

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          occurred_at: DateTime.t(),
          data:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Body of a `payment.succeeded` event. `currency` is an upcased ISO code, e.g. `\"EUR\"`."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Body of a `payment.failed` event."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Body of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment provider webhook payload (a map with string keys)
  into a `Payments.Webhook.Event` struct.

  Recognised types:

    * `"payment.succeeded"` → `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` → `Payments.Webhook.PaymentFailed`
    * `"refund.created"` → `Payments.Webhook.RefundCreated`

      {:ok, event} = Payments.Webhook.parse(payload)
      %Payments.Webhook.Event{data: %Payments.Webhook.PaymentSucceeded{amount: amount}} = event

  Amounts are integers in minor units (for example cents).
  Any other type returns `{:error, {:unsupported_type, type}}`, so the caller
  can acknowledge the event without processing it.
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- from_unix(created),
         {:ok, body} <- parse_body(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_body("payment.succeeded", data) do
    with {:ok, fields} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, fields)}
    end
  end

  defp parse_body("payment.failed", data) do
    with {:ok, fields} <- payment_fields(data),
         {:ok, reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok, struct!(PaymentFailed, Map.put(fields, :failure_reason, reason))}
    end
  end

  defp parse_body("refund.created", data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id") do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_body(type, _data), do: {:error, {:unsupported_type, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_minor_units(data, "amount"),
         {:ok, currency} <- fetch_currency(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email") do
      {:ok,
       %{payment_id: payment_id, amount: amount, currency: currency, customer_email: email}}
    end
  end

  defp from_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp fetch_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
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

  defp fetch_minor_units(data, key) do
    case Map.get(data, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_currency(data) do
    case Map.get(data, "currency") do
      code when is_binary(code) and byte_size(code) == 3 -> {:ok, String.upcase(code)}
      _ -> {:error, {:invalid_field, "currency"}}
    end
  end
end
