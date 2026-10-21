defmodule Payments.Webhook.PaymentEvent do
  @moduledoc """
  A payment outcome reported by the provider.

  `type` is `:payment_succeeded` or `:payment_failed`. `failure_reason` is
  only set for failed payments. `amount` is in minor units (cents).
  """

  @enforce_keys [:id, :type, :created_at, :payment_id, :amount, :currency]
  defstruct [
    :id,
    :type,
    :created_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed,
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundEvent do
  @moduledoc """
  A refund created for an earlier payment.

  `amount` is in minor units (cents) and may be `nil` if the provider did not
  send it.
  """

  @enforce_keys [:id, :created_at, :refund_id, :payment_id]
  defstruct [:id, :created_at, :refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment-provider webhook payloads into structs.

  ## Examples

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> })
      {:ok,
       %Payments.Webhook.RefundEvent{
         id: "evt_1",
         created_at: ~U[2024-09-22 09:46:40Z],
         refund_id: "re_1",
         payment_id: "pay_9",
         amount: nil,
         currency: nil
       }}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}
  """

  alias Payments.Webhook.PaymentEvent
  alias Payments.Webhook.RefundEvent

  @type error ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:ok, event}` with a `Payments.Webhook.PaymentEvent` or
  `Payments.Webhook.RefundEvent`, or `{:error, reason}`.
  """
  @spec parse(map()) :: {:ok, PaymentEvent.t() | RefundEvent.t()} | {:error, error()}
  def parse(%{"type" => type, "data" => %{} = data} = payload) when is_binary(type) do
    with {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created") do
      build_event(type, %{id: id, created_at: created_at}, data)
    end
  end

  def parse(%{"type" => type}) when not is_binary(type), do: {:error, {:invalid_field, "type"}}
  def parse(%{"type" => _type}), do: {:error, {:missing_field, "data"}}
  def parse(%{}), do: {:error, {:missing_field, "type"}}
  def parse(_payload), do: {:error, :invalid_payload}

  defp build_event("payment.succeeded", envelope, data) do
    with {:ok, fields} <- payment_fields(data) do
      {:ok,
       struct!(PaymentEvent, Map.merge(envelope, fields) |> Map.put(:type, :payment_succeeded))}
    end
  end

  defp build_event("payment.failed", envelope, data) do
    with {:ok, fields} <- payment_fields(data),
         {:ok, failure_reason} <- fetch_optional_string(data, "failure_reason") do
      event_fields =
        envelope
        |> Map.merge(fields)
        |> Map.merge(%{type: :payment_failed, failure_reason: failure_reason})

      {:ok, struct!(PaymentEvent, event_fields)}
    end
  end

  defp build_event("refund.created", envelope, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_optional_amount(data, "amount"),
         {:ok, currency} <- fetch_optional_string(data, "currency") do
      fields = %{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}
      {:ok, struct!(RefundEvent, Map.merge(envelope, fields))}
    end
  end

  defp build_event(type, _envelope, _data), do: {:error, {:unsupported_event, type}}

  defp payment_fields(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_string(data, "currency"),
         {:ok, customer_email} <- fetch_optional_string(data, "customer_email") do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _value} -> fetch_string(map, key)
    end
  end

  defp fetch_amount(map, key) do
    case Map.fetch(map, key) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_amount(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _amount} -> fetch_amount(map, key)
    end
  end

  defp fetch_timestamp(map, key) do
    with {:ok, seconds} <- fetch_unix_seconds(map, key),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      {:ok, datetime}
    else
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_unix_seconds(map, key) do
    case Map.fetch(map, key) do
      {:ok, seconds} when is_integer(seconds) -> {:ok, seconds}
      {:ok, _seconds} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
