defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `type` is one of `:payment_succeeded`, `:payment_failed`,
  `:refund_created`; `data` is a `Payments.Webhook.Payment` or `Payments.Webhook.Refund`
  to match that type.
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

defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment fields of a `payment.succeeded` or `payment.failed` event.
  `amount` is in integer minor units. `failure_reason` is `nil` unless the provider sets it.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The fields of a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into a `Payments.Webhook.Event`.

  Payloads are maps with string keys, as a JSON decoder produces them. Amounts
  are integer minor units (cents).

  Handled event types: `payment.succeeded`, `payment.failed`, `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @payment_kinds [:payment_succeeded, :payment_failed]

  @doc """
  Parses a webhook payload into an event.

  Returns `{:ok, event}` or `{:error, reason}`, where `reason` is one of:

    * `:invalid_payload` - a top-level key (`"id"`, `"type"`, `"created"`, `"data"`) is missing
    * `{:unsupported_event, type}` - the event type is not one this module handles
    * `{:missing_field, key}` - a required field inside `"data"` is absent
    * `{:invalid_field, key}` - a field is present but has the wrong type or value

  ## Examples

      iex> payload = %{"id" => "evt_1", "type" => "refund.created", "created" => 1727000000, "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}}
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.type
      :refund_created
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data}) do
    with {:ok, id} <- text(id, "id"),
         {:ok, kind} <- kind(type),
         {:ok, occurred_at} <- occurred_at(created),
         {:ok, payload} <- payload(kind, data) do
      {:ok, %Event{id: id, type: kind, occurred_at: occurred_at, data: payload}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp kind("payment.failed"), do: {:ok, :payment_failed}
  defp kind("refund.created"), do: {:ok, :refund_created}
  defp kind(other), do: {:error, {:unsupported_event, other}}

  defp occurred_at(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp payload(:refund_created, data) when is_map(data), do: refund(data)

  defp payload(kind, data) when kind in @payment_kinds and is_map(data), do: payment(data)

  defp payload(_kind, _data), do: {:error, {:invalid_field, "data"}}

  defp payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
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
      {:ok, value} -> text(value, key)
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

  defp text(value, _key) when is_binary(value), do: {:ok, value}
  defp text(_value, key), do: {:error, {:invalid_field, key}}
end
