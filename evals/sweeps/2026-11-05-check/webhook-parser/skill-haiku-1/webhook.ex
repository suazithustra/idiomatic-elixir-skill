defmodule Payments.Webhook do
  @moduledoc """
  Turns a webhook payload from the payment provider into event structs.

  The payload is the map produced by JSON decoding, with string keys. Amounts
  stay integer minor units (cents), as the provider sends them.

  Handled event types:

    * `payment.succeeded` becomes `Payments.Webhook.PaymentSucceeded`
    * `payment.failed` becomes `Payments.Webhook.PaymentFailed`
    * `refund.created` becomes `Payments.Webhook.RefundCreated`

  Any other type returns `{:error, {:unsupported_event, type}}`. The caller
  decides whether to acknowledge such events to the provider.
  """

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a decoded webhook payload into an event struct.

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}

  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, event_id} <- check(id, "id", &is_binary/1),
         {:ok, occurred_at} <- parse_created(created) do
      event_for(type, [event_id: event_id, occurred_at: occurred_at], data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_for("payment.succeeded", base, data) do
    with {:ok, payment} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, base ++ payment)}
    end
  end

  defp event_for("payment.failed", base, data) do
    with {:ok, payment} <- payment_fields(data) do
      failure = [failure_reason: data["failure_reason"]]
      {:ok, struct!(PaymentFailed, base ++ failure ++ payment)}
    end
  end

  defp event_for("refund.created", base, data) do
    with {:ok, refund_id} <- fetch_field(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- fetch_field(data, "payment_id", &is_binary/1) do
      {:ok, struct!(RefundCreated, base ++ [refund_id: refund_id, payment_id: payment_id])}
    end
  end

  defp event_for(type, _base, _data), do: {:error, {:unsupported_event, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- fetch_field(data, "payment_id", &is_binary/1),
         {:ok, amount} <- fetch_field(data, "amount", &minor_units?/1),
         {:ok, currency} <- fetch_field(data, "currency", &is_binary/1) do
      email = [customer_email: data["customer_email"]]
      {:ok, [payment_id: payment_id, amount: amount, currency: currency] ++ email}
    end
  end

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp fetch_field(data, key, validator) do
    case Map.fetch(data, key) do
      {:ok, value} -> check(value, key, validator)
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp check(value, key, validator) do
    if validator.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
  end

  defp minor_units?(value), do: is_integer(value) and value >= 0
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event. See `Payments.Webhook.parse/1`."

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
  @moduledoc "A `payment.failed` event. See `Payments.Webhook.parse/1`."

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
  @moduledoc "A `refund.created` event. See `Payments.Webhook.parse/1`."

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end
