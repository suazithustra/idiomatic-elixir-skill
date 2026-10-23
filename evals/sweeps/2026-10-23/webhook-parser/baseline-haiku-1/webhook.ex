defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` holds one of the typed event structs.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          data:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  A successful payment. `amount` is in minor units.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  A failed payment. `amount` is in minor units. `failure_reason` is `nil` when the
  provider does not give one.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email, :failure_reason]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  A refund on an existing payment.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into a `Payments.Webhook.Event`.

  The payload is a map with string keys, as produced by a JSON decoder.
  Amounts are integers in minor units (for example, cents).

  Handled event types:

    * `"payment.succeeded"` -> `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` -> `Payments.Webhook.PaymentFailed`
    * `"refund.created"` -> `Payments.Webhook.RefundCreated`
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error ::
          :malformed_payload
          | {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:invalid_timestamp, term()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:unsupported_type, type}}` for event types this app does not
  handle, so the caller can acknowledge and skip them.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created),
         {:ok, event_type, object} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, data: object}}
    end
  end

  def parse(_payload), do: {:error, :malformed_payload}

  defp parse_data("payment.succeeded", data) do
    with {:ok, fields} <- payment_fields(data) do
      {:ok, :payment_succeeded, struct!(PaymentSucceeded, fields)}
    end
  end

  defp parse_data("payment.failed", data) do
    with {:ok, fields} <- payment_fields(data),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok, :payment_failed, struct!(PaymentFailed, Map.put(fields, :failure_reason, reason))}
    end
  end

  defp parse_data("refund.created", data) do
    with {:ok, refund_id} <- required(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- required(data, "payment_id", &is_binary/1) do
      {:ok, :refund_created, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_data(type, _data), do: {:error, {:unsupported_type, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- required(data, "payment_id", &is_binary/1),
         {:ok, amount} <- required(data, "amount", &minor_units?/1),
         {:ok, currency} <- required(data, "currency", &currency_code?/1),
         {:ok, email} <- required(data, "customer_email", &is_binary/1) do
      {:ok, %{payment_id: payment_id, amount: amount, currency: currency, customer_email: email}}
    end
  end

  defp required(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp minor_units?(value), do: is_integer(value) and value >= 0

  defp currency_code?(value), do: is_binary(value) and byte_size(value) == 3

  defp to_datetime(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_timestamp, seconds}}
    end
  end
end
