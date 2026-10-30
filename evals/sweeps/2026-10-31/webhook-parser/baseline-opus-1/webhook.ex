defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  A `payment.succeeded` event.

  `amount` is in minor units and `currency` is an uppercase ISO 4217 code.
  """

  # Keeps personal data out of logs and crash reports.
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

  `amount` is in minor units and `currency` is an uppercase ISO 4217 code.
  """

  # Keeps personal data out of logs and crash reports.
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

  `amount` and `currency` are `nil` when the provider does not send them.
  Otherwise `amount` is in minor units and `currency` is an uppercase ISO 4217
  code.
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
  Turns decoded webhook payloads from the payment provider into event structs.

  `parse/1` expects a payload whose signature has already been verified. It
  returns an error tuple for bad input instead of raising, so a controller can
  decide the response from the result:

      case Payments.Webhook.parse(params) do
        {:ok, event} -> handle(event)
        {:error, {:unsupported_event_type, _type}} -> acknowledge(conn)
        {:error, _reason} -> reject(conn)
      end

  The provider can deliver an event more than once, so handlers should
  deduplicate on `event_id`.

  Identifiers, amounts and currencies are checked strictly. `customer_email`,
  `failure_reason` and the refund `amount` and `currency` may be missing,
  because the event is still worth recording without them.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:unsupported_event_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded webhook payload into an event struct.

  Errors name the field at fault but never include its value, so they are safe
  to log. `:invalid_payload` means the payload is not a map with a string
  `"type"`.

  ## Examples

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_1",
      ...>     "type" => "refund.created",
      ...>     "created" => 1_727_000_000,
      ...>     "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...>   })
      iex> event.refund_id
      "re_1"

      iex> Payments.Webhook.parse(%{"type" => "payout.paid"})
      {:error, {:unsupported_event_type, "payout.paid"}}

  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"type" => "payment.succeeded"} = payload) do
    with {:ok, envelope, data} <- envelope(payload),
         {:ok, payment} <- payment(data) do
      {:ok, struct!(PaymentSucceeded, Map.merge(envelope, payment))}
    end
  end

  def parse(%{"type" => "payment.failed"} = payload) do
    with {:ok, envelope, data} <- envelope(payload),
         {:ok, payment} <- payment(data),
         {:ok, failure_reason} <- optional(data, "failure_reason", :string) do
      fields = envelope |> Map.merge(payment) |> Map.put(:failure_reason, failure_reason)
      {:ok, struct!(PaymentFailed, fields)}
    end
  end

  def parse(%{"type" => "refund.created"} = payload) do
    with {:ok, envelope, data} <- envelope(payload),
         {:ok, refund_id} <- required(data, "refund_id", :id),
         {:ok, payment_id} <- required(data, "payment_id", :id),
         {:ok, amount} <- optional(data, "amount", :amount),
         {:ok, currency} <- optional(data, "currency", :currency) do
      refund = %{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}
      {:ok, struct!(RefundCreated, Map.merge(envelope, refund))}
    end
  end

  def parse(%{"type" => type}) when is_binary(type) do
    {:error, {:unsupported_event_type, type}}
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp envelope(payload) do
    with {:ok, event_id} <- required(payload, "id", :id),
         {:ok, created_at} <- required(payload, "created", :timestamp),
         {:ok, data} <- required(payload, "data", :map) do
      {:ok, %{event_id: event_id, created_at: created_at}, data}
    end
  end

  defp payment(data) do
    with {:ok, payment_id} <- required(data, "payment_id", :id),
         {:ok, amount} <- required(data, "amount", :amount),
         {:ok, currency} <- required(data, "currency", :currency),
         {:ok, customer_email} <- optional(data, "customer_email", :string) do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp required(map, key, type) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> cast(value, type, key)
    end
  end

  defp optional(map, key, type) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> cast(value, type, key)
    end
  end

  defp cast(value, :id, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp cast(value, :string, _key) when is_binary(value), do: {:ok, value}
  defp cast(value, :amount, _key) when is_integer(value) and value >= 0, do: {:ok, value}
  defp cast(value, :map, _key) when is_map(value), do: {:ok, value}

  defp cast(value, :timestamp, key) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end

  defp cast(value, :currency, key) when is_binary(value) do
    if value =~ ~r/\A[a-zA-Z]{3}\z/ do
      {:ok, String.upcase(value)}
    else
      {:error, {:invalid_field, key}}
    end
  end

  defp cast(_value, _type, key), do: {:error, {:invalid_field, key}}
end
