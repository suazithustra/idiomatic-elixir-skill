defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment as it appears in a payment webhook.

  `amount` is an integer in minor units (cents).
  """

  @enforce_keys [:id, :amount, :currency, :customer_email]
  defstruct [:id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  The `payment.succeeded` event.
  """

  @enforce_keys [:event_id, :occurred_at, :payment]
  defstruct [:event_id, :occurred_at, :payment]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment: Payments.Webhook.Payment.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  The `payment.failed` event. `failure_reason` is `nil` when the provider sends none.
  """

  @enforce_keys [:event_id, :occurred_at, :payment]
  defstruct [:event_id, :occurred_at, :payment, :failure_reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment: Payments.Webhook.Payment.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  The `refund.created` event.
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
  Turns a decoded webhook payload from the payment provider into a typed event.

  The payload is a map with string keys, as the JSON decoder returns it. Three
  event types are handled: `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type returns `{:error, {:unsupported_event, type}}`.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a decoded webhook payload into an event struct.

  Returns `{:error, :invalid_payload}` when the top-level keys are missing and
  `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}` when a
  field in `data` is absent or has the wrong type.

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}

  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data}) do
    with {:ok, event_id} <- non_empty_string(id, "id"),
         {:ok, occurred_at} <- occurred_at(created) do
      parse_event(type, event_id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # The type selects the event; the fields are checked in the helpers below.
  defp parse_event("payment.succeeded", event_id, occurred_at, data) do
    with {:ok, payment} <- parse_payment(data) do
      {:ok, %PaymentSucceeded{event_id: event_id, occurred_at: occurred_at, payment: payment}}
    end
  end

  defp parse_event("payment.failed", event_id, occurred_at, data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      event = %PaymentFailed{
        event_id: event_id,
        occurred_at: occurred_at,
        payment: payment,
        failure_reason: failure_reason
      }

      {:ok, event}
    end
  end

  defp parse_event("refund.created", event_id, occurred_at, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      event = %RefundCreated{
        event_id: event_id,
        occurred_at: occurred_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  defp parse_event(type, _event_id, _occurred_at, _data), do: {:error, {:unsupported_event, type}}

  defp occurred_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_payment(data) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- non_negative_integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      {:ok, %Payment{id: id, amount: amount, currency: currency, customer_email: customer_email}}
    end
  end

  defp fetch_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp string_field(data, key) do
    with {:ok, value} <- fetch_field(data, key) do
      non_empty_string(value, key)
    end
  end

  defp optional_string_field(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value -> non_empty_string(value, key)
    end
  end

  defp non_negative_integer_field(data, key) do
    with {:ok, value} <- fetch_field(data, key) do
      non_negative_integer(value, key)
    end
  end

  defp non_empty_string(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_string(_value, key), do: {:error, {:invalid_field, key}}

  defp non_negative_integer(value, _key) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value, key), do: {:error, {:invalid_field, key}}
end
