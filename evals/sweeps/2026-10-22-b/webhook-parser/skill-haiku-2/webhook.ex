defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `object` is a `Payments.Webhook.Payment` for payment
  events and a `Payments.Webhook.Refund` for refund events.
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
  A payment as reported by a `payment.succeeded` or `payment.failed` event.
  """

  @enforce_keys [:id, :amount, :currency, :customer_email]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

  @typedoc "`amount` is in minor units, for example cents."
  @type t :: %__MODULE__{
          id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  A refund as reported by a `refund.created` event.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id]

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns payment-provider webhook payloads into `Payments.Webhook.Event` structs.

  Payloads are maps decoded from JSON, with string keys. Handled event types:

    * `"payment.succeeded"` and `"payment.failed"`: `object` is a `Payments.Webhook.Payment`
    * `"refund.created"`: `object` is a `Payments.Webhook.Refund`
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @doc """
  Parses a decoded webhook payload into an event.

  Returns `{:ok, event}` when the type is handled and every required field is
  present and well-typed. Otherwise returns `{:error, reason}`.

  ## Examples

      iex> Payments.Webhook.parse(%{"type" => "dispute.opened"})
      {:error, {:unsupported_event, "dispute.opened"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_1",
      ...>     "type" => "refund.created",
      ...>     "created" => 1727000000,
      ...>     "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...>   })
      iex> event.object
      %Payments.Webhook.Refund{id: "re_1", payment_id: "pay_9"}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"type" => type} = payload) do
    with {:ok, kind} <- event_kind(type),
         {:ok, id} <- string_field(payload, "id"),
         {:ok, created} <- integer_field(payload, "created"),
         {:ok, occurred_at} <- to_datetime(created),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, object} <- parse_object(kind, data) do
      {:ok, %Event{id: id, type: kind, occurred_at: occurred_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # Explicit clauses instead of String.to_atom/1: the type comes from the
  # provider, and atoms are never garbage-collected.
  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp parse_object(:payment_succeeded, data), do: parse_payment(data)
  defp parse_object(:payment_failed, data), do: parse_payment(data)
  defp parse_object(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, email} <- string_field(data, "customer_email") do
      {:ok,
       %Payment{
         id: id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: data["failure_reason"]
       }}
    end
  end

  defp parse_refund(data) do
    with {:ok, id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{id: id, payment_id: payment_id}}
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

  defp to_datetime(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end
end
