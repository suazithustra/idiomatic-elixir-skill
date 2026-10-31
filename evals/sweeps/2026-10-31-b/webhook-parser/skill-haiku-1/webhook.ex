defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event from the payment provider."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct @enforce_keys

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
  @moduledoc "A `payment.failed` event from the payment provider."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct @enforce_keys ++ [:failure_reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A `refund.created` event from the payment provider."

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into a struct the app can use.

  The payload is a map with string keys, as a JSON decoder returns it. Amounts
  are integers in minor units (cents). Event types other than `payment.succeeded`,
  `payment.failed` and `refund.created` are rejected.
  """

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a webhook payload into a `PaymentSucceeded`, `PaymentFailed` or
  `RefundCreated` struct.

  Returns `{:error, {:unsupported_event, type}}` for other event types,
  `{:error, {:missing_field, key}}` when a field the event needs is absent, and
  `{:error, {:invalid_field, key}}` when it has the wrong shape. A payload that
  lacks the top-level keys returns `{:error, :invalid_payload}`.
  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, event_id} <- event_id(id),
         {:ok, kind} <- event_kind(type),
         {:ok, occurred_at} <- occurred_at(created) do
      build(kind, event_id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(type), do: {:error, {:unsupported_event, type}}

  defp build(:payment_succeeded, event_id, occurred_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      event = %PaymentSucceeded{
        event_id: event_id,
        occurred_at: occurred_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, event}
    end
  end

  defp build(:payment_failed, event_id, occurred_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- failure_reason(data) do
      event = %PaymentFailed{
        event_id: event_id,
        occurred_at: occurred_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, event}
    end
  end

  defp build(:refund_created, event_id, occurred_at, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      event = %RefundCreated{
        event_id: event_id,
        occurred_at: occurred_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  defp event_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp event_id(_id), do: {:error, {:invalid_field, "id"}}

  defp occurred_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(data) do
    case Map.fetch(data, "amount") do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:missing_field, "amount"}}
    end
  end

  defp failure_reason(data) do
    case data["failure_reason"] do
      nil -> {:ok, nil}
      reason when is_binary(reason) -> {:ok, reason}
      _other -> {:error, {:invalid_field, "failure_reason"}}
    end
  end
end
