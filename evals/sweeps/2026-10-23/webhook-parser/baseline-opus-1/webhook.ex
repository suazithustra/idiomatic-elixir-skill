defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into event structs.

  Payloads are maps with string keys, as produced by the JSON decoder. Verify
  the webhook signature against the raw request body before calling `parse/1`;
  this module only checks shape and types.

  Supported event types:

    * `"payment.succeeded"` -> `Payments.Webhook.PaymentSucceeded`
    * `"payment.failed"` -> `Payments.Webhook.PaymentFailed`
    * `"refund.created"` -> `Payments.Webhook.RefundCreated`

  Any other type returns `{:error, {:unsupported_type, type}}`, so the caller
  can acknowledge and drop it instead of making the provider retry.

  Amounts are kept as integer minor units. Currency codes are upcased
  (`"eur"` becomes `"EUR"`) and stay strings, so provider input never creates
  atoms.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @supported_types ["payment.succeeded", "payment.failed", "refund.created"]

  @doc """
  Parses a decoded webhook payload into one of the event structs.

  Errors name the provider's key (for example `{:missing_field, "amount"}`)
  and never include field values, so they are safe to log.

  ## Example

      {:ok, %Payments.Webhook.PaymentSucceeded{amount: 1250, currency: "EUR"}} =
        Payments.Webhook.parse(%{
          "id" => "evt_123",
          "type" => "payment.succeeded",
          "created" => 1727000000,
          "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur"}
        })

  """
  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"type" => type} = payload) when type in @supported_types do
    with {:ok, event_id} <- fetch(payload, "id", &id/1),
         {:ok, created_at} <- fetch(payload, "created", &unix_time/1),
         {:ok, data} <- fetch(payload, "data", &object/1) do
      build(type, data, %{event_id: event_id, created_at: created_at})
    end
  end

  def parse(%{"type" => type}) when is_binary(type), do: {:error, {:unsupported_type, type}}
  def parse(%{"type" => _type}), do: {:error, {:invalid_field, "type"}}
  def parse(payload) when is_map(payload), do: {:error, {:missing_field, "type"}}
  def parse(_payload), do: {:error, :invalid_payload}

  defp build("payment.succeeded", data, envelope) do
    with {:ok, payment} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, Map.merge(envelope, payment))}
    end
  end

  defp build("payment.failed", data, envelope) do
    with {:ok, payment} <- payment_fields(data),
         {:ok, failure_reason} <- fetch_optional(data, "failure_reason", &text/1) do
      fields = envelope |> Map.merge(payment) |> Map.put(:failure_reason, failure_reason)
      {:ok, struct!(PaymentFailed, fields)}
    end
  end

  defp build("refund.created", data, envelope) do
    with {:ok, refund_id} <- fetch(data, "refund_id", &id/1),
         {:ok, payment_id} <- fetch(data, "payment_id", &id/1),
         {:ok, amount} <- fetch(data, "amount", &amount/1),
         {:ok, currency} <- fetch(data, "currency", &currency/1) do
      fields = %{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}
      {:ok, struct!(RefundCreated, Map.merge(envelope, fields))}
    end
  end

  defp payment_fields(data) do
    with {:ok, payment_id} <- fetch(data, "payment_id", &id/1),
         {:ok, amount} <- fetch(data, "amount", &amount/1),
         {:ok, currency} <- fetch(data, "currency", &currency/1),
         {:ok, customer_email} <- fetch_optional(data, "customer_email", &text/1) do
      {:ok,
       %{payment_id: payment_id, amount: amount, currency: currency, customer_email: customer_email}}
    end
  end

  # A JSON null counts as missing for required fields.
  defp fetch(map, key, cast) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value -> cast_field(cast.(value), key)
    end
  end

  defp fetch_optional(map, key, cast) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> cast_field(cast.(value), key)
    end
  end

  defp cast_field({:ok, _value} = ok, _key), do: ok
  defp cast_field(:error, key), do: {:error, {:invalid_field, key}}

  defp id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp id(_value), do: :error

  defp text(value) when is_binary(value), do: {:ok, value}
  defp text(_value), do: :error

  defp amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp amount(_value), do: :error

  defp currency(value) when is_binary(value) do
    if value =~ ~r/\A[a-zA-Z]{3}\z/, do: {:ok, String.upcase(value)}, else: :error
  end

  defp currency(_value), do: :error

  defp unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp unix_time(_value), do: :error

  defp object(value) when is_map(value), do: {:ok, value}
  defp object(_value), do: :error
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A payment was captured."

  @enforce_keys [:event_id, :created_at, :payment_id, :amount, :currency]
  defstruct @enforce_keys ++ [:customer_email]

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
  @moduledoc "A payment attempt failed. `failure_reason` is the provider's text, if any."

  @enforce_keys [:event_id, :created_at, :payment_id, :amount, :currency]
  defstruct @enforce_keys ++ [:customer_email, :failure_reason]

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
  @moduledoc "A refund was created against an earlier payment."

  @enforce_keys [:event_id, :created_at, :refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }
end
