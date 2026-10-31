defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A payment completed successfully."

  @enforce_keys [:id, :created_at, :payment_id, :amount, :currency]
  defstruct [:id, :created_at, :payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A payment attempt failed."

  @enforce_keys [:id, :created_at, :payment_id, :amount, :currency]
  defstruct [:id, :created_at, :payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A refund was created against a payment."

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
  Parses decoded payment-provider webhook payloads (string-keyed maps) into structs.

  Amounts stay as integer minor units (for example cents).
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @supported_types ["payment.succeeded", "payment.failed", "refund.created"]

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          :invalid_payload
          | {:unsupported_event_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:unsupported_event_type, type}}` for event types we do not
  handle, so the caller can acknowledge them without treating them as failures.
  """
  @spec parse(map()) :: {:ok, event()} | {:error, error()}
  def parse(%{"type" => type}) when is_binary(type) and type not in @supported_types,
    do: {:error, {:unsupported_event_type, type}}

  def parse(%{"type" => type, "data" => %{} = data} = payload) when type in @supported_types do
    with {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- parse_created(Map.get(payload, "created")) do
      build(type, id, created_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp build("payment.succeeded", id, created_at, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         id: id,
         created_at: created_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end

  defp build("payment.failed", id, created_at, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_currency(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email"),
         {:ok, reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         id: id,
         created_at: created_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp build("refund.created", id, created_at, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_optional_amount(data),
         {:ok, currency} <- fetch_optional_currency(data) do
      {:ok,
       %RefundCreated{
         id: id,
         created_at: created_at,
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_), do: {:error, {:invalid_field, "created"}}

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, _} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_amount(map) do
    case Map.fetch(map, "amount") do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, nil} -> {:error, {:missing_field, "amount"}}
      {:ok, _} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:missing_field, "amount"}}
    end
  end

  defp fetch_optional_amount(map) do
    case Map.get(map, "amount") do
      nil -> {:ok, nil}
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _ -> {:error, {:invalid_field, "amount"}}
    end
  end

  defp fetch_currency(map) do
    with {:ok, currency} <- fetch_string(map, "currency"), do: normalize_currency(currency)
  end

  defp fetch_optional_currency(map) do
    case Map.get(map, "currency") do
      nil -> {:ok, nil}
      currency when is_binary(currency) -> normalize_currency(currency)
      _ -> {:error, {:invalid_field, "currency"}}
    end
  end

  # Provider sends lowercase ISO 4217 codes ("eur"); we use uppercase.
  defp normalize_currency(currency) do
    if String.length(currency) == 3,
      do: {:ok, String.upcase(currency)},
      else: {:error, {:invalid_field, "currency"}}
  end
end
