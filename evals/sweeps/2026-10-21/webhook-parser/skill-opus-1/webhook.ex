defmodule Payments.Webhook.ParseError do
  @moduledoc """
  Returned when a webhook payload cannot be turned into a `Payments.Webhook.Event`.

  `:reason` is one of:

    * `:unsupported_event_type` - the event type is not one we handle.
      `:event_type` holds the type from the payload.
    * `:missing_field` - a required field is absent or `null`. `:field` names it.
    * `:invalid_field` - a field has the wrong type or format. `:field` names it.

  Field names are keys in the payload or in its `"data"` object.
  """

  @type reason :: :unsupported_event_type | :missing_field | :invalid_field

  @type t :: %__MODULE__{
          reason: reason(),
          field: String.t() | nil,
          event_type: String.t() | nil
        }

  @enforce_keys [:reason]
  defexception [:reason, :field, :event_type]

  @impl true
  def message(%__MODULE__{reason: :unsupported_event_type, event_type: event_type}),
    do: "unsupported webhook event type #{inspect(event_type)}"

  def message(%__MODULE__{reason: :missing_field, field: field}),
    do: "missing field #{inspect(field)}"

  def message(%__MODULE__{reason: :invalid_field, field: field}),
    do: "invalid field #{inspect(field)}"
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment carried by a `payment.succeeded` or `payment.failed` event.

  `:amount` is in minor units (cents for EUR). `:currency` is an upper-case
  ISO 4217 code such as `"EUR"`. `:failure_reason` is usually set only on
  failed payments.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  # The email is personal data, so keep it out of logs and crash reports.
  @derive {Inspect, except: [:customer_email]}
  @enforce_keys [:id, :amount, :currency]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund carried by a `refund.created` event.

  `:payment_id` is the refunded payment. `:amount` is the refunded amount in
  minor units. `:currency` is an upper-case ISO 4217 code such as `"EUR"`.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }

  @enforce_keys [:id, :payment_id, :amount, :currency]
  defstruct @enforce_keys
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A webhook event from the payment provider.

  `:data` is a `Payments.Webhook.Payment` when `:type` is `:payment_succeeded`
  or `:payment_failed`, and a `Payments.Webhook.Refund` when `:type` is
  `:refund_created`.
  """

  alias Payments.Webhook.{Payment, Refund}

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct @enforce_keys
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into
  `Payments.Webhook.Event` structs.

  Handled event types:

    * `"payment.succeeded"` and `"payment.failed"`, with a
      `Payments.Webhook.Payment` as data
    * `"refund.created"`, with a `Payments.Webhook.Refund` as data

  Any other event type returns a `Payments.Webhook.ParseError` with reason
  `:unsupported_event_type`, so callers can acknowledge the webhook and skip it.
  """

  alias Payments.Webhook.{Event, ParseError, Payment, Refund}

  @doc """
  Parses a decoded webhook payload with string keys.

  Returns `{:ok, event}`, or `{:error, error}` where `error` is a
  `Payments.Webhook.ParseError` naming the unsupported event type or the
  missing or invalid field.

  ## Examples

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_123",
      ...>     "type" => "payment.succeeded",
      ...>     "created" => 1727000000,
      ...>     "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur"}
      ...>   })
      iex> {event.type, event.created_at, event.data.amount, event.data.currency}
      {:payment_succeeded, ~U[2024-09-22 10:13:20Z], 1250, "EUR"}

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_124",
      ...>   "type" => "customer.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{}
      ...> })
      {:error, %Payments.Webhook.ParseError{reason: :unsupported_event_type, event_type: "customer.created"}}

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_125",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"payment_id" => "pay_9", "amount" => 500, "currency" => "eur"}
      ...> })
      {:error, %Payments.Webhook.ParseError{reason: :missing_field, field: "refund_id"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, ParseError.t()}
  def parse(payload) when is_map(payload) do
    with {:ok, type_name} <- fetch_required(payload, "type", &cast_string/1),
         {:ok, type} <- parse_type(type_name),
         {:ok, id} <- fetch_required(payload, "id", &cast_id/1),
         {:ok, created_at} <- fetch_required(payload, "created", &cast_unix_time/1),
         {:ok, raw_data} <- fetch_required(payload, "data", &cast_map/1),
         {:ok, data} <- parse_data(type, raw_data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  @doc """
  Like `parse/1`, but returns the event directly and raises
  `Payments.Webhook.ParseError` when the payload cannot be parsed.

  Use it where a bad payload means a bug, such as in tests and fixtures.

  ## Examples

      iex> Payments.Webhook.parse!(%{
      ...>   "id" => "evt_126",
      ...>   "type" => "payment.failed",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"payment_id" => "pay_9", "amount" => "12.50", "currency" => "eur"}
      ...> })
      ** (Payments.Webhook.ParseError) invalid field "amount"
  """
  @spec parse!(map()) :: Event.t()
  def parse!(payload) do
    case parse(payload) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}

  defp parse_type(type_name),
    do: {:error, %ParseError{reason: :unsupported_event_type, event_type: type_name}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, id} <- fetch_required(data, "payment_id", &cast_id/1),
         {:ok, amount} <- fetch_required(data, "amount", &cast_amount/1),
         {:ok, currency} <- fetch_required(data, "currency", &cast_currency/1),
         {:ok, customer_email} <- fetch_optional(data, "customer_email", &cast_string/1),
         {:ok, failure_reason} <- fetch_optional(data, "failure_reason", &cast_string/1) do
      {:ok,
       %Payment{
         id: id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp parse_refund(data) do
    with {:ok, id} <- fetch_required(data, "refund_id", &cast_id/1),
         {:ok, payment_id} <- fetch_required(data, "payment_id", &cast_id/1),
         {:ok, amount} <- fetch_required(data, "amount", &cast_amount/1),
         {:ok, currency} <- fetch_required(data, "currency", &cast_currency/1) do
      {:ok, %Refund{id: id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp fetch_required(map, key, cast) do
    case map do
      %{^key => value} when not is_nil(value) -> cast_field(value, key, cast)
      %{} -> {:error, %ParseError{reason: :missing_field, field: key}}
    end
  end

  defp fetch_optional(map, key, cast) do
    case map do
      %{^key => value} when not is_nil(value) -> cast_field(value, key, cast)
      %{} -> {:ok, nil}
    end
  end

  defp cast_field(value, key, cast) do
    case cast.(value) do
      {:ok, cast_value} -> {:ok, cast_value}
      :error -> {:error, %ParseError{reason: :invalid_field, field: key}}
    end
  end

  defp cast_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp cast_id(_value), do: :error

  defp cast_string(value) when is_binary(value), do: {:ok, value}
  defp cast_string(_value), do: :error

  defp cast_amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp cast_amount(_value), do: :error

  defp cast_currency(value) when is_binary(value) do
    if String.match?(value, ~r/\A[a-zA-Z]{3}\z/), do: {:ok, String.upcase(value)}, else: :error
  end

  defp cast_currency(_value), do: :error

  defp cast_unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp cast_unix_time(_value), do: :error

  defp cast_map(value) when is_map(value), do: {:ok, value}
  defp cast_map(_value), do: :error
end
