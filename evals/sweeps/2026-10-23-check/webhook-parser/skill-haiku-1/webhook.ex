defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment from a `payment.succeeded` or `payment.failed` event.

  `amount` is in minor units (for example, cents).
  """

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
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

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `subject` is a `Payments.Webhook.Payment` for payment events and a
  `Payments.Webhook.Refund` for refund events.
  """

  @enforce_keys [:id, :type, :created_at, :subject]
  defstruct [:id, :type, :created_at, :subject]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          created_at: DateTime.t(),
          subject: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Event types other than `payment.succeeded`, `payment.failed` and
  `refund.created` return `{:error, {:unsupported_event, type}}`, so the caller
  can acknowledge them without treating them as failures.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @doc """
  Parses a payload with string keys into a `Payments.Webhook.Event`.

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "dispute.opened", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "dispute.opened"}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, created_at} <- parse_created_at(created),
         {:ok, subject} <- parse_subject(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, subject: subject}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_created_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_subject(:payment_succeeded, data), do: build_payment(data)
  defp parse_subject(:payment_failed, data), do: build_payment(data)
  defp parse_subject(:refund_created, data), do: build_refund(data)

  defp build_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
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

  defp build_refund(data) do
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

  defp integer_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
