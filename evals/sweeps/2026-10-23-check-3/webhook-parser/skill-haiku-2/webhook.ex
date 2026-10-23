defmodule Payments.Webhook.Event do
  @moduledoc """
  One parsed webhook event.

  `object` is a `Payments.Webhook.Payment` for the payment events and a
  `Payments.Webhook.Refund` for `:refund_created`.
  """

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          object: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment carried by a `payment.succeeded` or `payment.failed` event.

  Amounts are integer minor units (cents).
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
  @moduledoc "A refund carried by a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into structs the app can use.

  The payload is expected to have string keys, as a JSON decoder returns them.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` for `payment.succeeded`,
  `payment.failed` and `refund.created`. Otherwise returns `{:error, reason}`:

    * `:invalid_payload` - `id`, `type`, `created` or `data` is missing or has the wrong shape
    * `{:unsupported_event, type}` - the event type is not one this app handles
    * `{:missing_field, key}` - a field the event type needs is absent
    * `{:invalid_field, key}` - a field has the wrong type

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "dispute.created", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "dispute.created"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    # Check the type first, so an unknown type is reported even if its data is malformed.
    with {:ok, kind} <- parse_type(type),
         {:ok, object} <- parse_object(kind, data),
         {:ok, occurred_at} <- parse_time(created) do
      event = %Event{id: id, type: kind, occurred_at: occurred_at, object: object}
      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_object(:payment_succeeded, data), do: parse_payment(data)
  defp parse_object(:payment_failed, data), do: parse_payment(data)
  defp parse_object(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
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

  defp parse_time(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_time(_created), do: {:error, {:invalid_field, "created"}}

  defp string_field(data, key), do: field(data, key, &is_binary/1)

  defp integer_field(data, key), do: field(data, key, &is_integer/1)

  defp field(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end
end
