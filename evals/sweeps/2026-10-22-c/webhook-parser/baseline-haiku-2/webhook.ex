defmodule Payments.Webhook.Fields do
  @moduledoc false

  @spec string(map(), String.t()) :: {:ok, String.t()} | {:error, {:invalid_field, String.t()}}
  def string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  @spec amount(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, {:invalid_field, String.t()}}
  def amount(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  @spec optional_string(map(), String.t()) :: String.t() | nil
  def optional_string(data, key) do
    case Map.get(data, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data carried by a `payment.succeeded` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, {:invalid_field, String.t()}}
  def from_data(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.string(data, "currency") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: Fields.optional_string(data, "customer_email")
       }}
    end
  end
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data carried by a `payment.failed` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, {:invalid_field, String.t()}}
  def from_data(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.string(data, "currency") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: Fields.optional_string(data, "customer_email"),
         failure_reason: Fields.optional_string(data, "failure_reason")
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

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, {:invalid_field, String.t()}}
  def from_data(data) do
    with {:ok, refund_id} <- Fields.string(data, "refund_id"),
         {:ok, payment_id} <- Fields.string(data, "payment_id") do
      {:ok, %__MODULE__{refund_id: refund_id, payment_id: payment_id}}
    end
  end
end

defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event envelope."

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          occurred_at: DateTime.t(),
          object: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment-provider webhook payloads (string-keyed maps) into
  typed events.

  Amounts are kept as integer minor units. Timestamps are converted to
  UTC `DateTime` structs.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type parse_error ::
          :malformed_payload
          | :invalid_timestamp
          | {:unsupported_type, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a webhook payload into a `Payments.Webhook.Event`.

  Returns `{:error, {:unsupported_type, type}}` for event types the app does
  not handle, so callers can acknowledge and ignore them explicitly.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, parse_error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_integer(created) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created),
         {:ok, object} <- parse_object(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :malformed_payload}

  defp parse_object("payment.succeeded", data), do: PaymentSucceeded.from_data(data)
  defp parse_object("payment.failed", data), do: PaymentFailed.from_data(data)
  defp parse_object("refund.created", data), do: RefundCreated.from_data(data)
  defp parse_object(type, _data), do: {:error, {:unsupported_type, type}}

  defp to_datetime(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end
end
