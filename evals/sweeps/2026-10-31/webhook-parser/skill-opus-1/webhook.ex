defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment as reported by the provider.

  `amount` is in integer minor units. `failure_reason` is `nil` unless the provider sent one.
  """

  # The customer's email is personal data, so it stays out of logs and crash reports.
  @derive {Inspect, except: [:customer_email]}
  @enforce_keys [:id, :amount, :currency, :customer_email]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  A refund as reported by the provider.

  `amount` is in integer minor units. `amount` and `currency` are `nil` when the provider
  leaves them out.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A webhook event the app acts on.

  `resource` is a `Payments.Webhook.Payment` for `:payment_succeeded` and `:payment_failed`,
  and a `Payments.Webhook.Refund` for `:refund_created`.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @enforce_keys [:id, :type, :created_at, :resource]
  defstruct [:id, :type, :created_at, :resource]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          resource: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook.Error do
  @moduledoc """
  Why `Payments.Webhook.parse/1` rejected a payload.

  `reason` is one of:

    * `:invalid_payload` - the payload is not a map with `"id"`, `"type"`, `"created"` and
      a `"data"` map
    * `{:unsupported_event, type}` - the event type is not one the app handles
    * `{:missing_field, key}` - a required key is absent from `"data"`
    * `{:invalid_field, key}` - a key holds a value of the wrong type or out of range

  Apart from the event type, reasons name keys and never hold values, so an error is safe
  to log.
  """

  @enforce_keys [:reason]
  defexception [:reason]

  @type reason ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @type t :: %__MODULE__{reason: reason()}

  @impl true
  def message(%__MODULE__{reason: reason}), do: describe(reason)

  defp describe(:invalid_payload), do: "payload is not a webhook event"
  defp describe({:unsupported_event, type}), do: "unsupported event type #{inspect(type)}"
  defp describe({:missing_field, key}), do: "missing field #{inspect(key)}"
  defp describe({:invalid_field, key}), do: "invalid field #{inspect(key)}"
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into `Payments.Webhook.Event`
  structs.

  This module does not verify the provider's signature; do that before calling `parse/1`.

  Payment events require `"payment_id"`, `"amount"`, `"currency"` and `"customer_email"` in
  `"data"`. Refund events require `"refund_id"` and `"payment_id"`. A refund's `"amount"` and
  `"currency"` are kept when present, because a partial refund needs them, and may be absent.
  """

  alias Payments.Webhook.Error
  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a decoded payload into a `Payments.Webhook.Event`.

  Returns `{:error, %Payments.Webhook.Error{}}` when the payload is malformed or its event
  type is not supported.

  ## Examples

      iex> data = %{
      ...>   "payment_id" => "pay_9",
      ...>   "amount" => 1250,
      ...>   "currency" => "eur",
      ...>   "customer_email" => "a@example.com",
      ...>   "failure_reason" => nil
      ...> }
      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => data
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.created_at, event.resource.amount}
      {:payment_succeeded, ~U[2024-09-22 10:13:20Z], 1250}

      iex> payload = %{"id" => "evt_1", "type" => "refund.created", "created" => 0, "data" => %{}}
      iex> Payments.Webhook.parse(payload)
      {:error, %Payments.Webhook.Error{reason: {:missing_field, "refund_id"}}}

      iex> payload = %{"id" => "evt_1", "type" => "dispute.opened", "created" => 0, "data" => %{}}
      iex> Payments.Webhook.parse(payload)
      {:error, %Payments.Webhook.Error{reason: {:unsupported_event, "dispute.opened"}}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, %Payments.Webhook.Error{reason: :invalid_payload}}

  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, Error.t()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data}) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, event_id} <- parse_id(id),
         {:ok, created_at} <- parse_created(created),
         {:ok, resource} <- parse_resource(event_type, data) do
      {:ok, %Event{id: event_id, type: event_type, created_at: created_at, resource: resource}}
    end
  end

  def parse(_payload), do: error(:invalid_payload)

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: error({:unsupported_event, type})

  defp parse_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp parse_id(_id), do: error({:invalid_field, "id"})

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> error({:invalid_field, "created"})
    end
  end

  defp parse_created(_created), do: error({:invalid_field, "created"})

  defp parse_resource(:payment_succeeded, data), do: parse_payment(data)
  defp parse_resource(:payment_failed, data), do: parse_payment(data)
  defp parse_resource(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_field(data, "failure_reason", &string_field/2) do
      payment = %Payment{
        id: id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_field(data, "amount", &amount_field/2),
         {:ok, currency} <- optional_field(data, "currency", &string_field/2) do
      {:ok, %Refund{id: id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> error({:invalid_field, key})
      :error -> error({:missing_field, key})
    end
  end

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> error({:invalid_field, key})
      :error -> error({:missing_field, key})
    end
  end

  defp optional_field(data, key, parse_field) do
    if is_nil(data[key]), do: {:ok, nil}, else: parse_field.(data, key)
  end

  defp error(reason), do: {:error, %Error{reason: reason}}
end
