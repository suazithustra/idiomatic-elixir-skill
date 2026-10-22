defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `object` is the typed data for the event."

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          occurred_at: DateTime.t(),
          object: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc "The outcome of a payment, from a `payment.succeeded` or `payment.failed` event."

  @enforce_keys [:id, :status, :amount, :currency]
  defstruct [:id, :status, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :succeeded | :failed,
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @doc false
  @spec from_data(:succeeded | :failed, map()) ::
          {:ok, t()} | {:error, {:invalid_data | :invalid_field, String.t()}}
  def from_data(status, %{"payment_id" => id, "amount" => amount, "currency" => currency} = data)
      when is_binary(id) and is_integer(amount) and amount >= 0 do
    with {:ok, currency} <- normalize_currency(currency) do
      {:ok,
       %__MODULE__{
         id: id,
         status: status,
         amount: amount,
         currency: currency,
         customer_email: data["customer_email"],
         failure_reason: data["failure_reason"]
       }}
    else
      :error -> {:error, {:invalid_field, "currency"}}
    end
  end

  def from_data(_status, _data), do: {:error, {:invalid_data, "payment"}}

  defp normalize_currency(currency) when is_binary(currency) do
    code = String.upcase(currency)

    if Regex.match?(~r/\A[A-Z]{3}\z/, code), do: {:ok, code}, else: :error
  end

  defp normalize_currency(_currency), do: :error
end

defmodule Payments.Webhook.Refund do
  @moduledoc "A refund, from a `refund.created` event."

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id]

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, {:invalid_data, String.t()}}
  def from_data(%{"refund_id" => id, "payment_id" => payment_id})
      when is_binary(id) and is_binary(payment_id) do
    {:ok, %__MODULE__{id: id, payment_id: payment_id}}
  end

  def from_data(_data), do: {:error, {:invalid_data, "refund"}}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment provider webhook payloads into `Payments.Webhook.Event`
  structs.

  Event types other than `payment.succeeded`, `payment.failed` and `refund.created`
  return `{:error, {:unsupported_event_type, type}}`, so the caller can acknowledge
  and ignore them.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :malformed_payload
          | {:unsupported_event_type, String.t()}
          | {:invalid_data, String.t()}
          | {:invalid_field, String.t()}
          | {:invalid_timestamp, term()}

  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- from_unix(created),
         {:ok, object} <- parse_object(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :malformed_payload}

  defp parse_object("payment.succeeded", data), do: Payment.from_data(:succeeded, data)
  defp parse_object("payment.failed", data), do: Payment.from_data(:failed, data)
  defp parse_object("refund.created", data), do: Refund.from_data(data)
  defp parse_object(type, _data), do: {:error, {:unsupported_event_type, type}}

  defp from_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_timestamp, reason}}
    end
  end
end
