defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment carried by a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units, so `1250` with currency `"eur"` is 12.50 euros.
  `failure_reason` is `nil` on a payment that succeeded.
  """

  # Customer emails are personal data, so they stay out of logs and crash reports.
  @derive {Inspect, except: [:customer_email]}
  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund carried by a `refund.created` event.

  `amount` is in integer minor units. `amount` and `currency` are `nil` when the provider
  does not send them.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A webhook event from the payment provider.

  `id` is the provider's event id, which stays the same when a webhook is delivered again.
  `data` is a `Payments.Webhook.Payment` for the `:payment_succeeded` and `:payment_failed`
  types, and a `Payments.Webhook.Refund` for `:refund_created`.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct @enforce_keys

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into
  `Payments.Webhook.Event` structs.

  The checks follow these rules:

    * A field set to `null` counts as missing, because the provider sends `null` for a
      field that has no value.
    * `failure_reason` is required on `payment.failed` and ignored on `payment.succeeded`.
    * `amount` and `currency` are optional on `refund.created`, and checked when present.
    * `currency` and `failure_reason` stay strings. The provider decides their values, so
      they are not turned into atoms.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type reason ::
          :invalid_payload
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded webhook payload into an event.

  Returns `{:ok, event}`, or `{:error, reason}` where `reason` is one of:

    * `:invalid_payload` - the payload is not a map holding `"id"`, `"created"`, a string
      `"type"` and a map `"data"`.
    * `{:unsupported_event, type}` - the event type is not one this module handles.
    * `{:missing_field, key}` - a required field is absent or `null`.
    * `{:invalid_field, key}` - a field has the wrong type or an out-of-range value.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com",
      ...>     "failure_reason" => nil
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.created_at, event.data.amount}
      {:payment_succeeded, ~U[2024-09-22 10:13:20Z], 1250}

      iex> Payments.Webhook.parse(%{"id" => "evt_124", "type" => "payment.succeeded"})
      {:error, :invalid_payload}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, reason()}
  def parse(%{"id" => _id, "type" => type, "created" => _created, "data" => data} = payload)
      when is_binary(type) and is_map(data) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, id} <- string_field(payload, "id"),
         {:ok, seconds} <- non_neg_integer_field(payload, "created"),
         {:ok, created_at} <- parse_created(seconds),
         {:ok, event_data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_created(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_failed_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- non_neg_integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, payment}
    end
  end

  defp parse_failed_payment(data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, failure_reason} <- string_field(data, "failure_reason") do
      {:ok, %{payment | failure_reason: failure_reason}}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_field(data, "amount", &non_neg_integer_field/2),
         {:ok, currency} <- optional_field(data, "currency", &string_field/2) do
      refund = %Refund{
        refund_id: refund_id,
        payment_id: payment_id,
        amount: amount,
        currency: currency
      }

      {:ok, refund}
    end
  end

  defp string_field(fields, key) do
    case fields[key] do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp non_neg_integer_field(fields, key) do
    case fields[key] do
      nil -> {:error, {:missing_field, key}}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_field(fields, key, parse_field) do
    if is_nil(fields[key]), do: {:ok, nil}, else: parse_field.(fields, key)
  end
end
