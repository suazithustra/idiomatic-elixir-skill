defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `body` is a `Payments.Webhook.Payment` for payment
  events and a `Payments.Webhook.Refund` for refund events.
  """

  @enforce_keys [:id, :type, :occurred_at, :body]
  defstruct [:id, :type, :occurred_at, :body]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          body: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment from a `payment.succeeded` or `payment.failed` event.

  `amount` is in minor units (cents). `failure_reason` is `nil` unless the
  payment failed.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  A refund from a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload (string keys) into structs.

  Amounts stay as integer minor units, for example cents. Event types this
  module does not handle return `{:error, {:unsupported_event, type}}`, so the
  caller can acknowledge and skip them.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @doc """
  Parses a webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` for `payment.succeeded`,
  `payment.failed`, and `refund.created`. The event's `body` is a
  `Payments.Webhook.Payment` for payment events and a
  `Payments.Webhook.Refund` for refund events.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com",
      ...>     "failure_reason" => nil
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.type
      :payment_succeeded
      iex> event.body.amount
      1250
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, created} <- integer_field(payload, "created"),
         {:ok, occurred_at} <- parse_occurred_at(created),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, event_type} <- event_type(type),
         {:ok, body} <- parse_body(event_type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, body: body}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_body(type, data) when type in [:payment_succeeded, :payment_failed] do
    parse_payment(data)
  end

  defp parse_body(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_occurred_at(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp string_field(map, key), do: typed_field(map, key, &is_binary/1)
  defp integer_field(map, key), do: typed_field(map, key, &is_integer/1)
  defp map_field(map, key), do: typed_field(map, key, &is_map/1)

  defp typed_field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
    end
  end
end
