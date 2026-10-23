defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment in a `payment.succeeded` or `payment.failed` event.
  """

  @enforce_keys [:id, :amount, :currency]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund in a `refund.created` event.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id]

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `type` names the event, and `data` holds the
  `Payments.Webhook.Payment` or `Payments.Webhook.Refund` it describes.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          occurred_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a webhook payload from the payment provider into a `Payments.Webhook.Event`.

  The payload is the JSON document already decoded into a map with string keys.
  Amounts are integers in minor units (cents).

  Supported event types:

    * `"payment.succeeded"` and `"payment.failed"` carry a `Payments.Webhook.Payment`
    * `"refund.created"` carries a `Payments.Webhook.Refund`

  Any other type returns `{:error, {:unsupported_event, type}}`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @payment_types [:payment_succeeded, :payment_failed]

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  when a field the event needs is absent or has the wrong type.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.type
      :payment_succeeded
      iex> event.data.amount
      1250

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- fetch_field(payload, "id", &is_binary/1),
         {:ok, type} <- event_type(payload),
         {:ok, created} <- fetch_field(payload, "created", &is_integer/1),
         {:ok, occurred_at} <- to_datetime(created),
         {:ok, data} <- fetch_field(payload, "data", &is_map/1),
         {:ok, event_data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, data: event_data}}
    end
  end

  defp event_type(%{"type" => "payment.succeeded"}), do: {:ok, :payment_succeeded}
  defp event_type(%{"type" => "payment.failed"}), do: {:ok, :payment_failed}
  defp event_type(%{"type" => "refund.created"}), do: {:ok, :refund_created}
  defp event_type(%{"type" => type}), do: {:error, {:unsupported_event, type}}
  defp event_type(_payload), do: {:error, {:missing_field, "type"}}

  defp to_datetime(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_data(type, data) when type in @payment_types do
    parse_payment(data)
  end

  defp parse_data(:refund_created, data) do
    parse_refund(data)
  end

  defp parse_payment(data) do
    with {:ok, id} <- fetch_field(data, "payment_id", &is_binary/1),
         {:ok, amount} <- fetch_field(data, "amount", &non_negative_integer?/1),
         {:ok, currency} <- fetch_field(data, "currency", &is_binary/1),
         {:ok, customer_email} <- optional_string(data, "customer_email"),
         {:ok, failure_reason} <- optional_string(data, "failure_reason") do
      payment = %Payment{
        id: id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, id} <- fetch_field(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- fetch_field(data, "payment_id", &is_binary/1) do
      {:ok, %Refund{id: id, payment_id: payment_id}}
    end
  end

  defp fetch_field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
