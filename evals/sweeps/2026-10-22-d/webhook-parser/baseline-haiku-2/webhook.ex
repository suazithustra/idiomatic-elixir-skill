defmodule Payments.Webhook.Event do
  @moduledoc "A parsed payment provider webhook event."

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data carried by a `payment.succeeded` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency"),
         {:ok, customer_email} <- Fields.string(data, "customer_email") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data carried by a `payment.failed` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency, :customer_email, :failure_reason]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency"),
         {:ok, customer_email} <- Fields.string(data, "customer_email"),
         {:ok, failure_reason} <- Fields.optional_string(data, "failure_reason") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data carried by a `refund.created` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(data) do
    with {:ok, refund_id} <- Fields.string(data, "refund_id"),
         {:ok, payment_id} <- Fields.string(data, "payment_id") do
      {:ok, %__MODULE__{refund_id: refund_id, payment_id: payment_id}}
    end
  end
end

defmodule Payments.Webhook.Fields do
  @moduledoc false

  @spec string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  @spec optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  @spec amount(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def amount(data, key) do
    case Map.get(data, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  @spec currency(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def currency(data, key) do
    with {:ok, code} <- string(data, key) do
      if String.match?(code, ~r/\A[a-zA-Z]{3}\z/) do
        {:ok, String.upcase(code)}
      else
        {:error, {:invalid_field, key}}
      end
    end
  end
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment provider webhook payloads into `Payments.Webhook.Event`
  structs. The event's `data` is one of the event-specific payload structs:

    * `payment.succeeded` -> `Payments.Webhook.PaymentSucceeded`
    * `payment.failed`    -> `Payments.Webhook.PaymentFailed`
    * `refund.created`    -> `Payments.Webhook.RefundCreated`
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @event_types %{
    "payment.succeeded" => {:payment_succeeded, PaymentSucceeded},
    "payment.failed" => {:payment_failed, PaymentFailed},
    "refund.created" => {:refund_created, RefundCreated}
  }

  @doc """
  Parses a decoded webhook payload (string keys) into an event.

  Returns `{:error, {:unsupported_event_type, type}}` for event types we do not
  handle, so the caller can decide whether to acknowledge or reject them.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created),
         {:ok, event_type, payload} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, data: payload}}
    end
  end

  def parse(_payload), do: {:error, :malformed_payload}

  defp to_datetime(seconds) when is_integer(seconds), do: DateTime.from_unix(seconds)
  defp to_datetime(_seconds), do: {:error, {:invalid_field, "created"}}

  defp parse_data(type, data) do
    case Map.fetch(@event_types, type) do
      {:ok, {event_type, payload_module}} ->
        with {:ok, payload} <- payload_module.from_map(data), do: {:ok, event_type, payload}

      :error ->
        {:error, {:unsupported_event_type, type}}
    end
  end
end
