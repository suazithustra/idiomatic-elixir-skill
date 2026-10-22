defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  A payment the provider has collected.
  """

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  A payment the provider could not collect.
  """

  @enforce_keys [
    :event_id,
    :occurred_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]
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
          customer_email: String.t(),
          failure_reason: String.t()
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  A refund issued against an earlier payment.

  `amount` and `currency` are `nil` when the provider does not send them.
  """

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment provider webhook payloads into event structs.

  Amounts are integer minor units, as sent by the provider.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first bad field, and `{:error, {:unsupported_event, type}}` for event
  types the application does not handle.

  ## Examples

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> })
      {:ok,
       %Payments.Webhook.RefundCreated{
         event_id: "evt_1",
         occurred_at: ~U[2024-09-22 09:46:40Z],
         refund_id: "re_1",
         payment_id: "pay_9",
         amount: nil,
         currency: nil
       }}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, {:missing_field, "type"}}

      iex> Payments.Webhook.parse("nope")
      {:error, :invalid_payload}
  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{} = payload) do
    with {:ok, event_id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, occurred_at} <- timestamp_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data") do
      parse_event(type, %{event_id: event_id, occurred_at: occurred_at}, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_event("payment.succeeded", envelope, data) do
    with {:ok, payment} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, Map.merge(envelope, payment))}
    end
  end

  defp parse_event("payment.failed", envelope, data) do
    with {:ok, payment} <- payment_fields(data),
         {:ok, failure_reason} <- string_field(data, "failure_reason") do
      {:ok,
       struct!(
         PaymentFailed,
         Map.merge(envelope, Map.put(payment, :failure_reason, failure_reason))
       )}
    end
  end

  defp parse_event("refund.created", envelope, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_amount_field(data, "amount"),
         {:ok, currency} <- optional_string_field(data, "currency") do
      {:ok,
       %RefundCreated{
         event_id: envelope.event_id,
         occurred_at: envelope.occurred_at,
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  defp parse_event(type, _envelope, _data), do: {:error, {:unsupported_event, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> string_field(map, key)
      :error -> {:ok, nil}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> amount_field(map, key)
      :error -> {:ok, nil}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, %{} = value} -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp timestamp_field(map, key) do
    with {:ok, unix} <- integer_field(map, key) do
      case DateTime.from_unix(unix) do
        {:ok, datetime} -> {:ok, datetime}
        {:error, _reason} -> {:error, {:invalid_field, key}}
      end
    end
  end

  defp integer_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
