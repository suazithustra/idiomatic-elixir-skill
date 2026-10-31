defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment data from `payment.succeeded` and `payment.failed` events.

  `amount` is in integer minor units, such as cents for `"eur"`.
  """

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
  @moduledoc """
  Refund data from `refund.created` events.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `type` is `:payment_succeeded`, `:payment_failed` or `:refund_created`.
  `data` is a `Payments.Webhook.Payment` for the payment types and a
  `Payments.Webhook.Refund` for `:refund_created`.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a webhook payload from the payment provider into a
  `Payments.Webhook.Event`.

  The payload is a map with string keys, as a JSON decoder produces.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a webhook payload.

  Returns `{:ok, event}` or `{:error, reason}`. Possible reasons:

    * `:invalid_payload` - a top-level key is missing or has the wrong type
    * `{:unsupported_event, type}` - the event type is not handled here
    * `{:missing_field, key}` - a key in `data` is absent
    * `{:invalid_field, key}` - a key in `data` has the wrong type or value

  ## Examples

      iex> Payments.Webhook.parse(%{})
      {:error, :invalid_payload}

  """
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created),
         {:ok, kind} <- event_kind(type),
         {:ok, event_data} <- decode_data(kind, data) do
      event = %Event{id: id, type: kind, occurred_at: occurred_at, data: event_data}
      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # Event names come from outside the app. Each known name gets its own clause;
  # String.to_atom/1 would let a sender grow the atom table without limit.
  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp to_datetime(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp decode_data(kind, data) when kind in [:payment_succeeded, :payment_failed],
    do: payment(data)

  defp decode_data(:refund_created, data), do: refund(data)

  defp payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: data["customer_email"],
        failure_reason: data["failure_reason"]
      }

      {:ok, payment}
    end
  end

  defp refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(data) do
    case Map.fetch(data, "amount") do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:missing_field, "amount"}}
    end
  end
end
