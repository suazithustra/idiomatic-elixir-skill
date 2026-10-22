defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Body of a `payment.succeeded` event. `amount` is in minor units."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Body of a `payment.failed` event. `amount` is in minor units."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Body of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `data` is one of the event body structs."

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type kind :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: kind(),
          created_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into a typed event.

  Only `payment.succeeded`, `payment.failed` and `refund.created` are supported.
  Anything else returns `{:error, {:unsupported_type, type}}` so the caller can
  decide whether to acknowledge it.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, kind} <- kind(type),
         {:ok, created_at} <- created_at(created),
         {:ok, body} <- body(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :malformed_envelope}

  defp kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp kind("payment.failed"), do: {:ok, :payment_failed}
  defp kind("refund.created"), do: {:ok, :refund_created}
  defp kind(type), do: {:error, {:unsupported_type, type}}

  defp created_at(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp body(:payment_succeeded, data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- amount(data),
         {:ok, currency} <- currency(data),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end

  defp body(:payment_failed, data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- amount(data),
         {:ok, currency} <- currency(data),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp body(:refund_created, data) do
    with {:ok, refund_id} <- required_string(data, "refund_id"),
         {:ok, payment_id} <- required_string(data, "payment_id") do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp amount(data) do
    case Map.get(data, "amount") do
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _ -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp currency(data) do
    case required_string(data, "currency") do
      {:ok, code} when byte_size(code) == 3 -> {:ok, String.upcase(code)}
      _ -> {:error, {:invalid_field, "currency"}}
    end
  end

  defp required_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end
end
