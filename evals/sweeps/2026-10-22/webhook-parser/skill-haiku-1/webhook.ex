defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  A `payment.succeeded` webhook event.
  """

  @enforce_keys [:event_id, :created_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [:event_id, :created_at, :payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  A `payment.failed` webhook event. `failure_reason` is `nil` when the provider sends none.
  """

  @enforce_keys [
    :event_id,
    :created_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]
  defstruct [
    :event_id,
    :created_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  A `refund.created` webhook event.
  """

  @enforce_keys [:event_id, :created_at, :refund_id, :payment_id]
  defstruct [:event_id, :created_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          event_id: String.t(),
          created_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads into event structs.

  Payloads have string keys, as a JSON decoder returns them. Amounts are integer
  minor units (for example cents). The supported event types are `payment.succeeded`,
  `payment.failed`, and `refund.created`. Any other type returns
  `{:error, {:unsupported_event, type}}`.
  """

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @doc """
  Parses a webhook payload into an event struct.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  when a required field is absent or has the wrong type.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.refund_id
      "re_1"

  """
  @spec parse(term()) ::
          {:ok, PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()}
          | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, event_id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, created_at} <- timestamp_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data") do
      build_event(type, %{event_id: event_id, created_at: created_at}, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # Event type is selected here; each builder validates only its own fields,
  # so a known type with a bad field never reaches the unsupported clause.
  defp build_event("payment.succeeded", meta, data), do: payment_succeeded(meta, data)
  defp build_event("payment.failed", meta, data), do: payment_failed(meta, data)
  defp build_event("refund.created", meta, data), do: refund_created(meta, data)
  defp build_event(type, _meta, _data), do: {:error, {:unsupported_event, type}}

  defp payment_succeeded(meta, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         event_id: meta.event_id,
         created_at: meta.created_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp payment_failed(meta, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         event_id: meta.event_id,
         created_at: meta.created_at,
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp refund_created(meta, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok,
       %RefundCreated{
         event_id: meta.event_id,
         created_at: meta.created_at,
         refund_id: refund_id,
         payment_id: payment_id
       }}
    end
  end

  defp string_field(map, key), do: field(map, key, &is_binary/1)

  defp map_field(map, key), do: field(map, key, &is_map/1)

  defp amount_field(data), do: field(data, "amount", &non_negative_integer?/1)

  defp timestamp_field(map, key) do
    case field(map, key, &is_integer/1) do
      {:ok, seconds} -> unix_to_datetime(seconds, key)
      {:error, _reason} = error -> error
    end
  end

  defp unix_to_datetime(seconds, key) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end

  defp field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
