defmodule Payments.Webhook.Event do
  @moduledoc "A validated webhook event."

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          payload: Payments.Webhook.payload()
        }

  @enforce_keys [:id, :occurred_at, :payload]
  defstruct [:id, :occurred_at, :payload]
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Payload of a `payment.succeeded` event."

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email]
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Payload of a `payment.failed` event."

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Payload of a `refund.created` event."

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct [:refund_id, :payment_id, :amount, :currency]
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads (string-keyed maps) into event structs.

  Amounts are integer minor units. Unknown event types yield
  `{:error, {:unsupported_type, type}}` so callers can ack and ignore them.
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type payload :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:missing, String.t()}
          | {:invalid, String.t()}
          | {:unsupported_type, term()}

  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{} = raw) do
    with {:ok, id} <- fetch_string(raw, "id"),
         {:ok, type} <- fetch_string(raw, "type"),
         {:ok, occurred_at} <- fetch_timestamp(raw, "created"),
         {:ok, data} <- fetch_map(raw, "data"),
         {:ok, payload} <- parse_payload(type, data) do
      {:ok, %Event{id: id, occurred_at: occurred_at, payload: payload}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp parse_payload("payment.succeeded", data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
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

  defp parse_payload("payment.failed", data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
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

  defp parse_payload("refund.created", data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data) do
      {:ok,
       %RefundCreated{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  defp parse_payload(type, _data), do: {:error, {:unsupported_type, type}}

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:missing, key}}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      %{} = value -> {:ok, value}
      nil -> {:error, {:missing, key}}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp fetch_amount(data) do
    case Map.get(data, "amount") do
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      nil -> {:error, {:missing, "amount"}}
      _ -> {:error, {:invalid, "amount"}}
    end
  end

  defp fetch_currency(data) do
    with {:ok, currency} <- fetch_string(data, "currency") do
      {:ok, String.upcase(currency)}
    end
  end

  defp fetch_timestamp(map, key) do
    case Map.get(map, key) do
      ts when is_integer(ts) ->
        case DateTime.from_unix(ts) do
          {:ok, dt} -> {:ok, dt}
          {:error, _} -> {:error, {:invalid, key}}
        end

      nil ->
        {:error, {:missing, key}}

      _ ->
        {:error, {:invalid, key}}
    end
  end
end
