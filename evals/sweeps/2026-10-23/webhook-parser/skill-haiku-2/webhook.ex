defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment named by a `payment.succeeded` or `payment.failed` event.

  `customer_email` and `failure_reason` are optional in the payload and are
  `nil` when absent.
  """

  @enforce_keys [:id, :amount, :currency]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

  @typedoc "`amount` is in integer minor units, such as cents."
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
  A refund named by a `refund.created` event.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id]

  @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `object` is a `Payments.Webhook.Payment` for payment events and a
  `Payments.Webhook.Refund` for refund events.
  """

  @enforce_keys [:id, :type, :created_at, :object]
  defstruct [:id, :type, :created_at, :object]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          object: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into a
  `Payments.Webhook.Event`.

  Handles `payment.succeeded`, `payment.failed`, and `refund.created`.
  Amounts stay in integer minor units.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @doc """
  Parses a payload whose keys are strings, as produced by a JSON decoder.

  Returns `{:error, {:unsupported_event, type}}` for event types this module
  does not handle, `{:error, {:missing_field, key}}` when a required field of
  a known event is absent, and `{:error, {:invalid_field, key}}` when it has
  the wrong shape.

  ## Examples

      iex> payload = %{"id" => "evt_1", "type" => "refund.created", "created" => 1727000000, "data" => %{"refund_id" => "ref_1", "payment_id" => "pay_9"}}
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.type
      :refund_created

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data})
      when is_binary(id) do
    with {:ok, kind} <- event_kind(type),
         {:ok, created_at} <- parse_created_at(created),
         {:ok, object} <- parse_object(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(type), do: {:error, {:unsupported_event, type}}

  defp parse_created_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_object(:payment_succeeded, data), do: parse_payment(data)
  defp parse_object(:payment_failed, data), do: parse_payment(data)
  defp parse_object(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %Payment{
        id: id,
        amount: amount,
        currency: currency,
        customer_email: Map.get(data, "customer_email"),
        failure_reason: Map.get(data, "failure_reason")
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{id: id, payment_id: payment_id}}
    end
  end

  defp string_field(data, key), do: field(data, key, &is_binary/1)

  defp amount_field(data, key), do: field(data, key, &non_negative_integer?/1)

  defp field(data, key, check) do
    case Map.fetch(data, key) do
      {:ok, value} -> check_value(value, check, key)
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp check_value(value, check, key) do
    if check.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
