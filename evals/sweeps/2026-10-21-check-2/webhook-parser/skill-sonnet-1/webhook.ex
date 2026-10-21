defmodule Payments.Webhook.PaymentEvent do
  @moduledoc """
  A payment outcome reported by the provider (`payment.succeeded` or `payment.failed`).

  `amount` is in minor units (for example cents). `failure_reason` is only
  set on failed payments, and may still be `nil` there.
  """

  @enforce_keys [:id, :type, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [
    :id,
    :type,
    :occurred_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :succeeded | :failed,
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundEvent do
  @moduledoc """
  A refund created against an earlier payment (`refund.created`).

  `amount` and `currency` are optional in the provider payload and are `nil`
  when absent.
  """

  @enforce_keys [:id, :occurred_at, :refund_id, :payment_id]
  defstruct [:id, :occurred_at, :refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Fields do
  @moduledoc false

  @type result(value) ::
          {:ok, value} | {:error, {:missing_field, String.t()} | {:invalid_field, String.t()}}

  @spec string_field(map(), String.t()) :: result(String.t())
  def string_field(map, key) do
    case required(map, key) do
      {:ok, value} -> check(value, key, &non_empty_string?/1)
      {:error, _reason} = error -> error
    end
  end

  @spec amount_field(map(), String.t()) :: result(non_neg_integer())
  def amount_field(map, key) do
    case required(map, key) do
      {:ok, value} -> check(value, key, &non_neg_integer?/1)
      {:error, _reason} = error -> error
    end
  end

  @spec map_field(map(), String.t()) :: result(map())
  def map_field(map, key) do
    case required(map, key) do
      {:ok, value} -> check(value, key, &is_map/1)
      {:error, _reason} = error -> error
    end
  end

  @spec timestamp_field(map(), String.t()) :: result(DateTime.t())
  def timestamp_field(map, key) do
    with {:ok, seconds} <- required(map, key),
         {:ok, datetime} <- from_unix(seconds, key) do
      {:ok, datetime}
    end
  end

  @spec optional_string_field(map(), String.t()) :: result(String.t() | nil)
  def optional_string_field(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _value} -> string_field(map, key)
      %{} -> {:ok, nil}
    end
  end

  @spec optional_amount_field(map(), String.t()) :: result(non_neg_integer() | nil)
  def optional_amount_field(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => _value} -> amount_field(map, key)
      %{} -> {:ok, nil}
    end
  end

  defp required(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp check(value, key, valid?) do
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0

  defp from_unix(seconds, key) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end

  defp from_unix(_seconds, key), do: {:error, {:invalid_field, key}}
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses payment provider webhook payloads (already JSON-decoded, string keys)
  into structs the rest of the app can match on.

  Supported event types: `payment.succeeded`, `payment.failed` and
  `refund.created`. Amounts are integer minor units.
  """

  alias Payments.Webhook.Fields
  alias Payments.Webhook.PaymentEvent
  alias Payments.Webhook.RefundEvent

  @type event :: PaymentEvent.t() | RefundEvent.t()

  @type error ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  naming the first bad field, and `{:error, {:unsupported_event, type}}` for
  event types the app does not handle.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com",
      ...>     "failure_reason" => nil
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.payment_id, event.amount, event.currency}
      {:succeeded, "pay_9", 1250, "eur"}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "customer.created"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "refund.created", "created" => 1727000000, "data" => %{"payment_id" => "pay_9"}})
      {:error, {:missing_field, "refund_id"}}
  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- Fields.string_field(payload, "id"),
         {:ok, type} <- Fields.string_field(payload, "type"),
         {:ok, occurred_at} <- Fields.timestamp_field(payload, "created"),
         {:ok, data} <- Fields.map_field(payload, "data") do
      parse_event(type, %{id: id, occurred_at: occurred_at}, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_event("payment.succeeded", envelope, data),
    do: parse_payment(:succeeded, envelope, data)

  defp parse_event("payment.failed", envelope, data), do: parse_payment(:failed, envelope, data)
  defp parse_event("refund.created", envelope, data), do: parse_refund(envelope, data)
  defp parse_event(type, _envelope, _data), do: {:error, {:unsupported_event, type}}

  defp parse_payment(type, envelope, data) do
    with {:ok, payment_id} <- Fields.string_field(data, "payment_id"),
         {:ok, amount} <- Fields.amount_field(data, "amount"),
         {:ok, currency} <- Fields.string_field(data, "currency"),
         {:ok, customer_email} <- Fields.string_field(data, "customer_email"),
         {:ok, failure_reason} <- Fields.optional_string_field(data, "failure_reason") do
      {:ok,
       %PaymentEvent{
         id: envelope.id,
         type: type,
         occurred_at: envelope.occurred_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp parse_refund(envelope, data) do
    with {:ok, refund_id} <- Fields.string_field(data, "refund_id"),
         {:ok, payment_id} <- Fields.string_field(data, "payment_id"),
         {:ok, amount} <- Fields.optional_amount_field(data, "amount"),
         {:ok, currency} <- Fields.optional_string_field(data, "currency") do
      {:ok,
       %RefundEvent{
         id: envelope.id,
         occurred_at: envelope.occurred_at,
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end
end
