defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment provider webhook payload into event structs.

  `parse/1` takes the map produced by JSON decoding, with string keys, and returns
  `{:ok, event}`, where `event` is one of the structs nested in this module, or an
  error tuple. Amounts are integer minor units, and `created_at` is a UTC `DateTime`
  built from the envelope's Unix `created` timestamp.

  Event types other than `payment.succeeded`, `payment.failed` and `refund.created`
  return `{:error, {:unsupported_event, type}}`, so the caller decides whether to
  acknowledge them. A missing field returns `{:error, {:missing_field, key}}`, and a
  field of the wrong type or value returns `{:error, {:invalid_field, key}}`.

  `payment.failed` is assumed to carry the same payment fields as `payment.succeeded`,
  plus a `failure_reason` that may be `nil`.
  """

  defmodule Payment do
    @moduledoc "The payment an event is about. `amount` is in integer minor units."

    @enforce_keys [:id, :amount, :currency, :customer_email]
    defstruct [:id, :amount, :currency, :customer_email]

    @type t :: %__MODULE__{
            id: String.t(),
            amount: non_neg_integer(),
            currency: String.t(),
            customer_email: String.t()
          }
  end

  defmodule PaymentSucceeded do
    @moduledoc "A `payment.succeeded` event."

    @enforce_keys [:event_id, :created_at, :payment]
    defstruct [:event_id, :created_at, :payment]

    @type t :: %__MODULE__{
            event_id: String.t(),
            created_at: DateTime.t(),
            payment: Payment.t()
          }
  end

  defmodule PaymentFailed do
    @moduledoc "A `payment.failed` event."

    @enforce_keys [:event_id, :created_at, :payment, :failure_reason]
    defstruct [:event_id, :created_at, :payment, :failure_reason]

    @type t :: %__MODULE__{
            event_id: String.t(),
            created_at: DateTime.t(),
            payment: Payment.t(),
            failure_reason: String.t() | nil
          }
  end

  defmodule RefundCreated do
    @moduledoc "A `refund.created` event."

    @enforce_keys [:event_id, :created_at, :refund_id, :payment_id]
    defstruct [:event_id, :created_at, :refund_id, :payment_id]

    @type t :: %__MODULE__{
            event_id: String.t(),
            created_at: DateTime.t(),
            refund_id: String.t(),
            payment_id: String.t()
          }
  end

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a decoded webhook payload into an event struct.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_3", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, refund} = Payments.Webhook.parse(payload)
      iex> refund.payment_id
      "pay_9"
  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(payload) do
    with {:ok, event_id} <- required_field(payload, "id", &is_binary/1),
         {:ok, type} <- required_field(payload, "type", &is_binary/1),
         {:ok, created} <- required_field(payload, "created", &is_integer/1),
         {:ok, created_at} <- parse_created(created),
         {:ok, data} <- required_field(payload, "data", &is_map/1) do
      parse_event(type, event_id, created_at, data)
    end
  end

  # The type is selected here and each clause validates only its own fields, so a known
  # event with a missing field reports that field instead of falling through to the
  # catch-all clause.
  defp parse_event("payment.succeeded", event_id, created_at, data) do
    case parse_payment(data) do
      {:ok, payment} ->
        {:ok, %PaymentSucceeded{event_id: event_id, created_at: created_at, payment: payment}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_event("payment.failed", event_id, created_at, data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, failure_reason} <- required_field(data, "failure_reason", &nullable_string?/1) do
      event = %PaymentFailed{
        event_id: event_id,
        created_at: created_at,
        payment: payment,
        failure_reason: failure_reason
      }

      {:ok, event}
    end
  end

  defp parse_event("refund.created", event_id, created_at, data) do
    with {:ok, refund_id} <- required_field(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- required_field(data, "payment_id", &is_binary/1) do
      event = %RefundCreated{
        event_id: event_id,
        created_at: created_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  defp parse_event(type, _event_id, _created_at, _data), do: {:error, {:unsupported_event, type}}

  defp parse_payment(data) do
    with {:ok, id} <- required_field(data, "payment_id", &is_binary/1),
         {:ok, amount} <- required_field(data, "amount", &non_negative_integer?/1),
         {:ok, currency} <- required_field(data, "currency", &is_binary/1),
         {:ok, customer_email} <- required_field(data, "customer_email", &is_binary/1) do
      payment = %Payment{
        id: id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, payment}
    end
  end

  defp parse_created(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp required_field(map, key, check) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if check.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp nullable_string?(value), do: is_nil(value) or is_binary(value)
end
