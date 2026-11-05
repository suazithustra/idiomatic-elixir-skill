defmodule Payments.Webhook.PaymentEvent do
  @moduledoc """
  A `payment.succeeded` or `payment.failed` event from the payment provider.

  `status` is `:succeeded` or `:failed`. `amount` is in minor units (cents).
  `failure_reason` is `nil` unless the provider sent one.
  """

  @enforce_keys [:id, :status, :created_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [
    :id,
    :status,
    :created_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :succeeded | :failed,
          created_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundEvent do
  @moduledoc """
  A `refund.created` event from the payment provider.
  """

  @enforce_keys [:id, :created_at, :refund_id, :payment_id]
  defstruct [:id, :created_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into a struct.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.PaymentEvent
  alias Payments.Webhook.RefundEvent

  @type event :: PaymentEvent.t() | RefundEvent.t()

  @type error ::
          :invalid_payload
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed payload into an event struct.

  Returns `{:error, {:unsupported_event, type}}` for an event type we do not
  handle, and `{:missing_field, key}` or `{:invalid_field, key}` when a field of
  a supported event is absent or has the wrong shape.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.refund_id, event.payment_id}
      {"re_1", "pay_9"}

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_2",
      ...>   "type" => "invoice.paid",
      ...>   "created" => 1727000000,
      ...>   "data" => %{}
      ...> })
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_3"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, event()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, created_at} <- parse_created(created) do
      parse_event(type, id, created_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} ->
        {:ok, created_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_event("payment.succeeded", id, created_at, data) do
    parse_payment(:succeeded, id, created_at, data)
  end

  defp parse_event("payment.failed", id, created_at, data) do
    parse_payment(:failed, id, created_at, data)
  end

  defp parse_event("refund.created", id, created_at, data) do
    parse_refund(id, created_at, data)
  end

  defp parse_event(type, _id, _created_at, _data), do: {:error, {:unsupported_event, type}}

  defp parse_payment(status, id, created_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      event = %PaymentEvent{
        id: id,
        status: status,
        created_at: created_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, event}
    end
  end

  defp parse_refund(id, created_at, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      event = %RefundEvent{
        id: id,
        created_at: created_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) or is_nil(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:ok, nil}
    end
  end

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
