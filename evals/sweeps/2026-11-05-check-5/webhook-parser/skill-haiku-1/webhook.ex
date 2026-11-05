defmodule Payments.Webhook.Event do
  @moduledoc """
  One parsed webhook event.

  `type` is `:payment_succeeded`, `:payment_failed` or `:refund_created`.
  `data` is a `Payments.Webhook.Payment` for the payment types and a
  `Payments.Webhook.Refund` for `:refund_created`.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment data from a `payment.succeeded` or `payment.failed` event.

  `amount` is in minor units of `currency`. `failure_reason` is set for
  failed payments and `nil` otherwise.
  """

  @enforce_keys [:id, :amount, :currency]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Refund data from a `refund.created` event.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id]

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into structs.

  The payload is a map with string keys, as a JSON decoder produces it.
  Amounts are integer minor units (for example, cents).

  Handled event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type returns `{:error, {:unsupported_event, type}}`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a webhook payload into a `Payments.Webhook.Event`.

  Returns `{:error, reason}` where `reason` is `:invalid_payload`,
  `{:unsupported_event, type}`, `{:missing_field, key}` or
  `{:invalid_field, key}`.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"type" => type, "data" => data} = payload) when is_map(data) do
    with {:ok, kind} <- event_kind(type),
         {:ok, id} <- string_field(payload, "id"),
         {:ok, seconds} <- integer_field(payload, "created"),
         {:ok, occurred_at} <- unix_datetime(seconds),
         {:ok, body} <- parse_data(kind, data) do
      event = %Event{id: id, type: kind, occurred_at: occurred_at, data: body}
      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %Payment{
        id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: Map.get(data, "customer_email"),
        failure_reason: Map.get(data, "failure_reason")
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      refund = %Refund{id: refund_id, payment_id: payment_id}
      {:ok, refund}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp unix_datetime(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end
end
