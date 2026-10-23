defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  A `payment.succeeded` webhook event. Amounts are integer minor units.
  """

  @enforce_keys [:event_id, :created_at, :payment_id, :amount, :currency, :customer_email]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  A `payment.failed` webhook event. `failure_reason` is `nil` when the provider gives none.
  """

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
          amount: integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  A `refund.created` webhook event.
  """

  @enforce_keys [:event_id, :created_at, :refund_id, :payment_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment provider webhook payloads into structs the app can use.

  Payloads are maps with string keys, as a JSON decoder produces them. Only the
  event types in `parse/1` are supported.
  """

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @typedoc "An event the application handles."
  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a decoded webhook payload into the struct for its event type.

  Returns `{:error, :invalid_payload}` when the envelope is missing a key,
  `{:error, {:unsupported_event, type}}` for an event type this module does not
  handle, and `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  when a field the event type needs is absent or has the wrong type.

  ## Examples

      iex> payload = %{"id" => "evt_1", "type" => "payment.succeeded", "created" => 1727000000, "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur", "customer_email" => "a@example.com"}}
      iex> {:ok, %Payments.Webhook.PaymentSucceeded{amount: 1250}} = Payments.Webhook.parse(payload)
  """
  @spec parse(term()) :: {:ok, event()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, created_at} <- parse_created(created),
         {:ok, event} <- parse_event(type, id, created_at, data) do
      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # Selects the event type here and validates the fields in the clause for that
  # type, so a known type with a missing field reports that field, not an unsupported event.
  defp parse_event("payment.succeeded", id, created_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      event = %PaymentSucceeded{
        event_id: id,
        created_at: created_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, event}
    end
  end

  defp parse_event("payment.failed", id, created_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- nullable_string_field(data, "failure_reason") do
      event = %PaymentFailed{
        event_id: id,
        created_at: created_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, event}
    end
  end

  defp parse_event("refund.created", id, created_at, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      event = %RefundCreated{
        event_id: id,
        created_at: created_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  # The provider sends many event types we do not handle. The caller acknowledges
  # these without acting on them, so this is an error value, not a crash.
  defp parse_event(type, _id, _created_at, _data), do: {:error, {:unsupported_event, type}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp string_field(data, key), do: field(data, key, &is_binary/1)

  defp integer_field(data, key), do: field(data, key, &is_integer/1)

  defp nullable_string_field(data, key) do
    field(data, key, fn value -> is_nil(value) or is_binary(value) end)
  end

  defp field(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
