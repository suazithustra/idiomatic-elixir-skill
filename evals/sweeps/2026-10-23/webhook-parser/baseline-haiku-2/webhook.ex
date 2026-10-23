defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event."

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          occurred_at: DateTime.t(),
          data: struct()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads (maps with string keys)
  into typed event structs.

  Supported event types:

    * `payment.succeeded` -> `Payments.Webhook.PaymentSucceeded`
    * `payment.failed`    -> `Payments.Webhook.PaymentFailed`
    * `refund.created`    -> `Payments.Webhook.RefundCreated`

  Any other type returns `{:error, {:unsupported_type, type}}`.
  Amounts are integer minor units (for example, cents).
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @doc """
  Parses a webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` with `:data` set to one of the
  event-specific structs, or `{:error, reason}`.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, occurred_at} <- to_datetime(created),
         {:ok, body} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_data("payment.succeeded", data), do: PaymentSucceeded.from_data(data)
  defp parse_data("payment.failed", data), do: PaymentFailed.from_data(data)
  defp parse_data("refund.created", data), do: RefundCreated.from_data(data)
  defp parse_data(type, _data), do: {:error, {:unsupported_type, type}}

  defp to_datetime(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_created, created}}
    end
  end

  defp to_datetime(created), do: {:error, {:invalid_created, created}}
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data for a `payment.succeeded` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) do
    with {:ok, payment_id} <- Fields.required_string(data, "payment_id"),
         {:ok, amount} <- Fields.required_amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data),
         {:ok, email} <- Fields.optional_string(data, "customer_email") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data for a `payment.failed` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          failure_reason: String.t() | nil
        }

  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) do
    with {:ok, payment_id} <- Fields.required_string(data, "payment_id"),
         {:ok, amount} <- Fields.required_amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data),
         {:ok, reason} <- Fields.optional_string(data, "failure_reason") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         failure_reason: reason
       }}
    end
  end
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data for a `refund.created` event."

  alias Payments.Webhook.Fields

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}

  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) do
    with {:ok, refund_id} <- Fields.required_string(data, "refund_id"),
         {:ok, payment_id} <- Fields.required_string(data, "payment_id") do
      {:ok, %__MODULE__{refund_id: refund_id, payment_id: payment_id}}
    end
  end
end

defmodule Payments.Webhook.Fields do
  @moduledoc false

  # Field extractors shared by the event-specific parsers.

  @currency_format ~r/\A[A-Za-z]{3}\z/

  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def required_string(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
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

  @spec required_amount(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def required_amount(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  # Stored upcased (ISO 4217 style, e.g. "EUR") so later comparisons are simple.
  @spec currency(map()) :: {:ok, String.t()} | {:error, term()}
  def currency(data) do
    case Map.fetch(data, "currency") do
      {:ok, code} when is_binary(code) ->
        if Regex.match?(@currency_format, code),
          do: {:ok, String.upcase(code)},
          else: {:error, {:invalid_field, "currency"}}

      _ ->
        {:error, {:invalid_field, "currency"}}
    end
  end
end
