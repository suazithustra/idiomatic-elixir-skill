defmodule Payments.Webhook do
  @moduledoc """
  Turns a webhook payload from the payment provider into a `Payments.Webhook.Event`.

  The payload is the decoded JSON map with string keys. Amounts are integer
  minor units (cents). Event types other than `payment.succeeded`,
  `payment.failed` and `refund.created` are rejected.
  """

  defmodule Payment do
    @moduledoc "Payment data carried by `payment.succeeded` and `payment.failed` events."

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

  defmodule Refund do
    @moduledoc "Refund data carried by `refund.created` events."

    @enforce_keys [:refund_id, :payment_id]
    defstruct [:refund_id, :payment_id]

    @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
  end

  defmodule Event do
    @moduledoc "A parsed webhook event. `data` is a `Payment` or a `Refund`."

    @enforce_keys [:id, :type, :occurred_at, :data]
    defstruct [:id, :type, :occurred_at, :data]

    @type t :: %__MODULE__{
            id: String.t(),
            type: :payment_succeeded | :payment_failed | :refund_created,
            occurred_at: DateTime.t(),
            data: Payment.t() | Refund.t()
          }
  end

  @payment_types [:payment_succeeded, :payment_failed]

  @doc """
  Parses a decoded webhook payload into an event.

  Returns `{:ok, %Payments.Webhook.Event{}}` for a supported event. Errors:

    * `{:error, :invalid_payload}` - a top-level key is missing or `data` is not a map
    * `{:error, {:unsupported_event, type}}` - the event type is not one the app handles
    * `{:error, {:missing_field, key}}` - a required field under `data` is absent
    * `{:error, {:invalid_field, key}}` - a field under `data` has the wrong type
  """
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data}) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, occurred_at} <- parse_created(created),
         {:ok, body} <- parse_body(event_type, data) do
      event = %Event{id: id, type: event_type, occurred_at: occurred_at, data: body}
      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_body(:refund_created, data), do: parse_refund(data)
  defp parse_body(type, data) when type in @payment_types, do: parse_payment(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: Map.get(data, "customer_email"),
        failure_reason: Map.get(data, "failure_reason")
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      refund = %Refund{refund_id: refund_id, payment_id: payment_id}
      {:ok, refund}
    end
  end

  defp string_field(data, key), do: validated_field(data, key, &is_binary/1)

  defp amount_field(data) do
    validated_field(data, "amount", &(is_integer(&1) and &1 >= 0))
  end

  defp validated_field(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
