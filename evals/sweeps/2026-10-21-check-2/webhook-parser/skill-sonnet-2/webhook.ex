defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data of a `payment.succeeded` event. `amount` is in minor units."

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
  Data of a `payment.failed` event. `amount` is in minor units.

  `failure_reason` is `nil` when the provider sent none.
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
  @moduledoc "Data of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated webhook event.

  `data` is a `Payments.Webhook.PaymentSucceeded`, `Payments.Webhook.PaymentFailed`
  or `Payments.Webhook.RefundCreated` struct; match on it to dispatch.
  """

  @enforce_keys [:id, :occurred_at, :data]
  defstruct [:id, :occurred_at, :data]

  @type data ::
          Payments.Webhook.PaymentSucceeded.t()
          | Payments.Webhook.PaymentFailed.t()
          | Payments.Webhook.RefundCreated.t()

  @type t :: %__MODULE__{id: String.t(), occurred_at: DateTime.t(), data: data()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads into structs.

  Payloads are string-keyed maps, as produced by a JSON decoder. `parse/1`
  validates the envelope and the event-specific fields and returns a
  `Payments.Webhook.Event` whose `data` is one of `Payments.Webhook.PaymentSucceeded`,
  `Payments.Webhook.PaymentFailed` or `Payments.Webhook.RefundCreated`.

  Amounts are integers in minor units (for example cents).
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type error_reason ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first bad field, and `{:error, {:unsupported_event, type}}` for event
  types the application does not handle, so callers can acknowledge those
  without treating them as failures.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.id
      "evt_123"
      iex> event.data
      %Payments.Webhook.RefundCreated{refund_id: "re_1", payment_id: "pay_9"}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "payment.succeeded", "created" => 1727000000, "data" => %{}})
      {:error, {:missing_field, "payment_id"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse("not a map")
      {:error, :invalid_payload}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error_reason()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- field(payload, "id", &parse_string/1),
         {:ok, type} <- field(payload, "type", &parse_string/1),
         {:ok, occurred_at} <- field(payload, "created", &parse_unix_time/1),
         {:ok, data} <- field(payload, "data", &parse_map/1),
         {:ok, event_data} <- parse_event(type, data) do
      {:ok, %Event{id: id, occurred_at: occurred_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_event("payment.succeeded", data) do
    with {:ok, payment} <- parse_payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, payment)}
    end
  end

  defp parse_event("payment.failed", data) do
    with {:ok, payment} <- parse_payment_fields(data),
         {:ok, failure_reason} <- optional_field(data, "failure_reason", &parse_string/1) do
      {:ok, struct!(PaymentFailed, Map.put(payment, :failure_reason, failure_reason))}
    end
  end

  defp parse_event("refund.created", data) do
    with {:ok, refund_id} <- field(data, "refund_id", &parse_string/1),
         {:ok, payment_id} <- field(data, "payment_id", &parse_string/1) do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_event(type, _data), do: {:error, {:unsupported_event, type}}

  defp parse_payment_fields(data) do
    with {:ok, payment_id} <- field(data, "payment_id", &parse_string/1),
         {:ok, amount} <- field(data, "amount", &parse_amount/1),
         {:ok, currency} <- field(data, "currency", &parse_string/1),
         {:ok, customer_email} <- field(data, "customer_email", &parse_string/1) do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp field(map, key, parser) do
    with {:ok, raw} <- fetch_required(map, key) do
      cast(raw, key, parser)
    end
  end

  defp optional_field(map, key, parser) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, raw} -> cast(raw, key, parser)
      :error -> {:ok, nil}
    end
  end

  defp fetch_required(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp cast(raw, key, parser) do
    case parser.(raw) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp parse_string(_value), do: :error

  defp parse_map(value) when is_map(value), do: {:ok, value}
  defp parse_map(_value), do: :error

  defp parse_amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_amount(_value), do: :error

  defp parse_unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp parse_unix_time(_value), do: :error
end
