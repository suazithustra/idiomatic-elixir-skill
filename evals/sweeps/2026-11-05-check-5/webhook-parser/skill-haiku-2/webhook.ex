defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is a `Payment` for payment events and a
  `Refund` for refund events.
  """

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          created_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment data from a `payment.succeeded` or `payment.failed` event.
  `amount` is in minor units. `failure_reason` is `nil` unless the provider sends one.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email, :failure_reason]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Refund data from a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into structs.

  The payload is a map with string keys, as a JSON decoder returns it.
  Amounts are integers in minor units (cents). Three event types are
  supported: `payment.succeeded`, `payment.failed` and `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @payment_types [:payment_succeeded, :payment_failed]

  @doc """
  Parses a webhook payload into an `Event`.

  Returns `{:error, {:unsupported_event, type}}` for an event type this module
  does not handle, `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` for a bad field, and
  `{:error, :invalid_payload}` when the envelope keys are absent or wrong.

  ## Examples

      iex> Payments.Webhook.parse(%{})
      {:error, :invalid_payload}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, created_at} <- parse_created_at(created),
         {:ok, event_data} <- parse_data(event_type, data) do
      event = %Event{
        id: id,
        type: event_type,
        created_at: created_at,
        data: event_data
      }

      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} ->
        {:ok, created_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(type, data) when type in @payment_types, do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- required(data, "payment_id", &is_binary/1),
         {:ok, amount} <- required(data, "amount", &non_negative_integer?/1),
         {:ok, currency} <- required(data, "currency", &currency_code?/1),
         {:ok, customer_email} <- optional(data, "customer_email", &is_binary/1),
         {:ok, failure_reason} <- optional(data, "failure_reason", &is_binary/1) do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- required(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- required(data, "payment_id", &is_binary/1) do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp required(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} -> check(value, key, valid?)
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional(data, key, valid?) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value -> check(value, key, valid?)
    end
  end

  defp check(value, key, valid?) do
    if valid?.(value) do
      {:ok, value}
    else
      {:error, {:invalid_field, key}}
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp currency_code?(value), do: is_binary(value) and byte_size(value) == 3
end
