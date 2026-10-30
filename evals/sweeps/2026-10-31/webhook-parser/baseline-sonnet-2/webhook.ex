defmodule Payments.Webhook.Payment do
  @moduledoc "Payload of `payment.succeeded` and `payment.failed`. Amount is in minor units."

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

defmodule Payments.Webhook.Refund do
  @moduledoc "Payload of `refund.created`. Amount and currency are nil if the provider omits them."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `data` is a `Payment` or a `Refund` depending on `type`."

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload (string-keyed map) into
  an `t:Payments.Webhook.Event.t/0`.

  Supported event types: `payment.succeeded`, `payment.failed`, `refund.created`.
  Amounts are integer minor units.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:unsupported_type, String.t()}
          | {:missing, String.t()}
          | {:invalid, String.t()}

  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, id} <- fetch_string(id, "id"),
         {:ok, created_at} <- parse_timestamp(created),
         {:ok, parsed} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: event_type(type), created_at: created_at, data: parsed}}
    end
  end

  def parse(%{} = payload) do
    case Enum.find(~w(id type created data), &(not Map.has_key?(payload, &1))) do
      nil -> {:error, {:invalid, "data"}}
      key -> {:error, {:missing, key}}
    end
  end

  def parse(_), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: :payment_succeeded
  defp event_type("payment.failed"), do: :payment_failed
  defp event_type("refund.created"), do: :refund_created

  defp parse_data("payment.succeeded", data), do: parse_payment(data)
  defp parse_data("payment.failed", data), do: parse_payment(data)
  defp parse_data("refund.created", data), do: parse_refund(data)
  defp parse_data(type, _data) when is_binary(type), do: {:error, {:unsupported_type, type}}
  defp parse_data(_type, _data), do: {:error, {:invalid, "type"}}

  defp parse_payment(data) do
    with {:ok, payment_id} <- fetch_string(data["payment_id"], "payment_id"),
         {:ok, amount} <- fetch_amount(data["amount"]),
         {:ok, currency} <- fetch_currency(data["currency"]),
         {:ok, email} <- optional_string(data["customer_email"], "customer_email"),
         {:ok, reason} <- optional_string(data["failure_reason"], "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- fetch_string(data["refund_id"], "refund_id"),
         {:ok, payment_id} <- fetch_string(data["payment_id"], "payment_id"),
         {:ok, amount} <- optional_amount(data["amount"]),
         {:ok, currency} <- optional_currency(data["currency"]) do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp fetch_string(nil, field), do: {:error, {:missing, field}}
  defp fetch_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp fetch_string(_value, field), do: {:error, {:invalid, field}}

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, field), do: fetch_string(value, field)

  defp fetch_amount(nil), do: {:error, {:missing, "amount"}}
  defp fetch_amount(amount) when is_integer(amount) and amount >= 0, do: {:ok, amount}
  defp fetch_amount(_), do: {:error, {:invalid, "amount"}}

  defp optional_amount(nil), do: {:ok, nil}
  defp optional_amount(amount), do: fetch_amount(amount)

  # Currency is normalised to an upper-case ISO 4217 code, e.g. "eur" -> "EUR".
  defp fetch_currency(nil), do: {:error, {:missing, "currency"}}

  defp fetch_currency(code) when is_binary(code) do
    if code =~ ~r/\A[A-Za-z]{3}\z/,
      do: {:ok, String.upcase(code)},
      else: {:error, {:invalid, "currency"}}
  end

  defp fetch_currency(_), do: {:error, {:invalid, "currency"}}

  defp optional_currency(nil), do: {:ok, nil}
  defp optional_currency(code), do: fetch_currency(code)

  defp parse_timestamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> {:ok, dt}
      {:error, _} -> {:error, {:invalid, "created"}}
    end
  end

  defp parse_timestamp(nil), do: {:error, {:missing, "created"}}
  defp parse_timestamp(_), do: {:error, {:invalid, "created"}}
end
