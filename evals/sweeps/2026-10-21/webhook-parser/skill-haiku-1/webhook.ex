defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into a typed event.

  The payload is a map with string keys, as a JSON decoder returns it. Each
  supported event type becomes one struct. Unsupported types and malformed
  fields return an error tuple.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a webhook payload into an event struct.

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "payment.pending", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "payment.pending"}}

  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, event_id} <- fetch_field(payload, "id", &non_empty_string?/1),
         {:ok, type} <- fetch_field(payload, "type", &non_empty_string?/1),
         {:ok, occurred_at} <- fetch_occurred_at(payload),
         {:ok, details} <- fetch_field(payload, "data", &is_map/1) do
      parse_event(type, %{event_id: event_id, occurred_at: occurred_at}, details)
    end
  end

  # Selecting the type only looks at the type string. Field checks happen in
  # the builders below, so a known type with a bad field never reaches the
  # catch-all clause.
  defp parse_event("payment.succeeded", envelope, details),
    do: payment_succeeded(envelope, details)

  defp parse_event("payment.failed", envelope, details),
    do: payment_failed(envelope, details)

  defp parse_event("refund.created", envelope, details),
    do: refund_created(envelope, details)

  defp parse_event(type, _envelope, _details), do: {:error, {:unsupported_event, type}}

  defp payment_succeeded(envelope, details) do
    with {:ok, fields} <- payment_fields(details) do
      {:ok, struct!(PaymentSucceeded, Map.merge(envelope, fields))}
    end
  end

  defp payment_failed(envelope, details) do
    with {:ok, fields} <- payment_fields(details),
         {:ok, failure_reason} <- optional_field(details, "failure_reason", &is_binary/1) do
      fields = Map.put(fields, :failure_reason, failure_reason)
      {:ok, struct!(PaymentFailed, Map.merge(envelope, fields))}
    end
  end

  defp refund_created(envelope, details) do
    with {:ok, refund_id} <- fetch_field(details, "refund_id", &non_empty_string?/1),
         {:ok, payment_id} <- fetch_field(details, "payment_id", &non_empty_string?/1) do
      fields = %{refund_id: refund_id, payment_id: payment_id}
      {:ok, struct!(RefundCreated, Map.merge(envelope, fields))}
    end
  end

  defp payment_fields(details) do
    with {:ok, payment_id} <- fetch_field(details, "payment_id", &non_empty_string?/1),
         {:ok, amount} <- fetch_field(details, "amount", &minor_units?/1),
         {:ok, currency} <- fetch_field(details, "currency", &non_empty_string?/1),
         {:ok, customer_email} <- optional_field(details, "customer_email", &is_binary/1) do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp fetch_occurred_at(payload) do
    with {:ok, created} <- fetch_field(payload, "created", &is_integer/1) do
      case DateTime.from_unix(created) do
        {:ok, occurred_at} -> {:ok, occurred_at}
        {:error, _reason} -> {:error, {:invalid_field, "created"}}
      end
    end
  end

  defp fetch_field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_field(map, key, valid?) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp minor_units?(value), do: is_integer(value) and value >= 0
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event. `amount` is in minor units."

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
  @moduledoc "A `payment.failed` event. `amount` is in minor units."

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
