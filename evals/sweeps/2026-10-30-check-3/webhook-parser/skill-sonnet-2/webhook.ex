defmodule Payments.Webhook.PaymentEvent do
  @moduledoc """
  A payment event from the provider: `:payment_succeeded` or `:payment_failed`.

  `amount` is an integer in minor units (1250 is 12.50 in a two-decimal currency).
  `currency` is the upper-case currency code. `customer_email` and `failure_reason`
  are `nil` when the provider sends none.
  """

  @enforce_keys [:event_id, :type, :occurred_at, :payment_id, :amount, :currency]
  defstruct [
    :event_id,
    :type,
    :occurred_at,
    :payment_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          type: :payment_succeeded | :payment_failed,
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundEvent do
  @moduledoc """
  A `refund.created` event from the provider.
  """

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload (string-keyed map) into a struct.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.

  ## Errors

    * `{:error, :invalid_payload}` - the payload lacks `"id"`, `"type"`,
      `"created"` or `"data"`, or one of them has the wrong type
    * `{:error, {:unsupported_event, type}}` - the event type is not one we handle
    * `{:error, {:missing_field, key}}` - a field of `"data"` is absent
    * `{:error, {:invalid_field, key}}` - a field has the wrong type or value
  """

  alias Payments.Webhook.PaymentEvent
  alias Payments.Webhook.RefundEvent

  @type event :: PaymentEvent.t() | RefundEvent.t()
  @type reason ::
          :invalid_payload
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a webhook payload into an event struct.

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

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, event()} | {:error, reason()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, kind} <- parse_type(type),
         {:ok, occurred_at} <- parse_created(created) do
      build(kind, id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type(type) do
    case type do
      "payment.succeeded" -> {:ok, :payment_succeeded}
      "payment.failed" -> {:ok, :payment_failed}
      "refund.created" -> {:ok, :refund_created}
      other -> {:error, {:unsupported_event, other}}
    end
  end

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} ->
        {:ok, occurred_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp build(:refund_created, event_id, occurred_at, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      event = %RefundEvent{
        event_id: event_id,
        occurred_at: occurred_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  defp build(kind, event_id, occurred_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      event = %PaymentEvent{
        event_id: event_id,
        type: kind,
        occurred_at: occurred_at,
        payment_id: payment_id,
        amount: amount,
        currency: String.upcase(currency),
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, event}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
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
