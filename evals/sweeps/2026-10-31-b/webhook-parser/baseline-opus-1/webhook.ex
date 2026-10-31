defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  A `payment.succeeded` event.

  `amount` is in minor units of `currency`. `customer_email` is `nil` when the
  provider does not send one.
  """

  # Keeps the email out of logs and crash reports.
  @derive {Inspect, except: [:customer_email]}
  @enforce_keys [:event_id, :created_at, :payment_id, :amount, :currency, :customer_email]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  A `payment.failed` event.

  `amount` is in minor units of `currency`. `customer_email` and
  `failure_reason` are `nil` when the provider does not send them.
  """

  # Keeps the email out of logs and crash reports.
  @derive {Inspect, except: [:customer_email]}
  @enforce_keys [
    :event_id,
    :created_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  A `refund.created` event.

  Only `refund_id` and `payment_id` are guaranteed. `amount` (in minor units of
  `currency`) and `currency` are `nil` when the provider does not send them.
  """

  @enforce_keys [:event_id, :created_at, :refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into structs.

  `parse/1` returns one struct per event type, so callers can match on the
  events they handle and treat the two kinds of error differently:

      case Payments.Webhook.parse(payload) do
        {:ok, %PaymentSucceeded{} = event} -> fulfil(event)
        {:ok, %PaymentFailed{} = event} -> notify(event)
        {:ok, %RefundCreated{} = event} -> record(event)
        {:error, {:unsupported_type, _type}} -> :ignore
        {:error, reason} -> {:reject, reason}
      end

  An unsupported type is a valid event we have no use for, so it should be
  acknowledged. Anything else is a malformed payload.

  Required fields are the ones needed to act on an event: ids, timestamp,
  payment amount and currency. A missing or `null` `customer_email` or
  `failure_reason` becomes `nil` rather than an error, so that a money event is
  not dropped for lack of a detail. A field that is present with the wrong type
  is always an error.

  `{:invalid_field, name}` errors carry the field name but not its value, which
  keeps customer data out of logs.

  This module does not check authenticity. Verify the provider's signature on
  the raw request body before decoding it. Providers can deliver an event more
  than once, so use `event_id` to discard duplicates.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:unsupported_type, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded payload into an event struct.

  ## Examples

      iex> Payments.Webhook.parse(%{"type" => "customer.updated"})
      {:error, {:unsupported_type, "customer.updated"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "refund.created"})
      {:error, {:invalid_field, "created"}}

  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"type" => "payment.succeeded"} = payload) do
    build(PaymentSucceeded, payload, &payment_fields/1)
  end

  def parse(%{"type" => "payment.failed"} = payload) do
    build(PaymentFailed, payload, &failed_payment_fields/1)
  end

  def parse(%{"type" => "refund.created"} = payload) do
    build(RefundCreated, payload, &refund_fields/1)
  end

  def parse(%{"type" => type}) when is_binary(type), do: {:error, {:unsupported_type, type}}
  def parse(_payload), do: {:error, :invalid_payload}

  defp build(module, payload, data_fields) do
    with {:ok, event_id} <- field(payload, "id", &id/1),
         {:ok, created_at} <- field(payload, "created", &timestamp/1),
         {:ok, data} <- field(payload, "data", &object/1),
         {:ok, fields} <- data_fields.(data) do
      {:ok, struct!(module, Map.merge(fields, %{event_id: event_id, created_at: created_at}))}
    end
  end

  defp payment_fields(data) do
    with {:ok, payment_id} <- field(data, "payment_id", &id/1),
         {:ok, amount} <- field(data, "amount", &amount/1),
         {:ok, currency} <- field(data, "currency", &currency/1),
         {:ok, customer_email} <- field(data, "customer_email", optional(&text/1)) do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp failed_payment_fields(data) do
    with {:ok, fields} <- payment_fields(data),
         {:ok, failure_reason} <- field(data, "failure_reason", optional(&text/1)) do
      {:ok, Map.put(fields, :failure_reason, failure_reason)}
    end
  end

  defp refund_fields(data) do
    with {:ok, refund_id} <- field(data, "refund_id", &id/1),
         {:ok, payment_id} <- field(data, "payment_id", &id/1),
         {:ok, amount} <- field(data, "amount", optional(&amount/1)),
         {:ok, currency} <- field(data, "currency", optional(&currency/1)) do
      {:ok, %{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp field(map, key, validate) do
    case validate.(Map.get(map, key)) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp optional(validate) do
    fn
      nil -> {:ok, nil}
      value -> validate.(value)
    end
  end

  defp id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp id(_value), do: :error

  defp text(value) when is_binary(value), do: {:ok, value}
  defp text(_value), do: :error

  defp object(value) when is_map(value), do: {:ok, value}
  defp object(_value), do: :error

  defp amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp amount(_value), do: :error

  # Stays a string: atoms are never garbage collected, so input from outside
  # must not create them.
  defp currency(value) when is_binary(value) do
    if value =~ ~r/\A[a-zA-Z]{3}\z/, do: {:ok, String.upcase(value)}, else: :error
  end

  defp currency(_value), do: :error

  defp timestamp(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp timestamp(_value), do: :error
end
