defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment as described by a `payment.succeeded` or `payment.failed` webhook.

  `amount` is in integer minor units of `currency` (for example cents),
  and `currency` is an upper-case ISO 4217 code such as `"EUR"`.
  """

  @enforce_keys [:id, :amount, :currency]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

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
  A refund as described by a `refund.created` webhook.

  `amount` and `currency` are `nil` when the provider leaves them out.
  """

  @enforce_keys [:id, :payment_id]
  defstruct [:id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `object` is a `Payments.Webhook.Payment` for the payment events and a
  `Payments.Webhook.Refund` for `:refund_created`.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @enforce_keys [:id, :type, :created_at, :object]
  defstruct [:id, :type, :created_at, :object]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          object: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook.Error do
  @moduledoc """
  The reason a webhook payload could not be parsed.

  `reason` is one of:

    * `{:missing_field, key}` - a required key is absent or `nil`
    * `{:invalid_field, key}` - a key holds a value of the wrong type or format
    * `{:unsupported_event, type}` - the event type is not one this app handles
    * `:invalid_payload` - the payload is not a map
  """

  defexception [:reason]

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, term()}
          | :invalid_payload

  @type t :: %__MODULE__{reason: reason()}

  @impl true
  def message(%__MODULE__{reason: {:missing_field, key}}), do: "missing field #{inspect(key)}"
  def message(%__MODULE__{reason: {:invalid_field, key}}), do: "invalid field #{inspect(key)}"

  def message(%__MODULE__{reason: {:unsupported_event, type}}) do
    "unsupported event type #{inspect(type)}"
  end

  def message(%__MODULE__{reason: :invalid_payload}), do: "webhook payload must be a map"
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment provider webhook payloads into `Payments.Webhook.Event` structs.

  Payloads arrive as JSON decoded into string-keyed maps. Handled event types:

    * `"payment.succeeded"` - `object` is a `Payments.Webhook.Payment`
    * `"payment.failed"` - `object` is a `Payments.Webhook.Payment`
    * `"refund.created"` - `object` is a `Payments.Webhook.Refund`

  Any other event type returns an `{:unsupported_event, type}` error, so callers
  can acknowledge and ignore events they do not handle.
  """

  alias Payments.Webhook.Error
  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a decoded webhook payload.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.object.amount, event.object.currency}
      {:payment_succeeded, 1250, "EUR"}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created"})
      {:error, %Payments.Webhook.Error{reason: {:unsupported_event, "customer.created"}}}

  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, Error.t()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- required_field(payload, "id", &cast_string/1),
         {:ok, type_name} <- required_field(payload, "type", &cast_string/1),
         {:ok, type} <- parse_type(type_name),
         {:ok, created_at} <- required_field(payload, "created", &cast_unix_time/1),
         {:ok, data} <- required_field(payload, "data", &cast_map/1),
         {:ok, object} <- parse_object(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, object: object}}
    end
  end

  def parse(_payload), do: error(:invalid_payload)

  @doc """
  Parses a decoded webhook payload, raising `Payments.Webhook.Error` if it is invalid.
  """
  @spec parse!(term()) :: Event.t()
  def parse!(payload) do
    case parse(payload) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: error({:unsupported_event, type})

  defp parse_object(:payment_succeeded, data), do: parse_payment(data)
  defp parse_object(:payment_failed, data), do: parse_payment(data)
  defp parse_object(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, id} <- required_field(data, "payment_id", &cast_string/1),
         {:ok, amount} <- required_field(data, "amount", &cast_amount/1),
         {:ok, currency} <- required_field(data, "currency", &cast_currency/1),
         {:ok, customer_email} <- optional_field(data, "customer_email", &cast_string/1),
         {:ok, failure_reason} <- optional_field(data, "failure_reason", &cast_string/1) do
      payment = %Payment{
        id: id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, id} <- required_field(data, "refund_id", &cast_string/1),
         {:ok, payment_id} <- required_field(data, "payment_id", &cast_string/1),
         {:ok, amount} <- optional_field(data, "amount", &cast_amount/1),
         {:ok, currency} <- optional_field(data, "currency", &cast_currency/1) do
      {:ok, %Refund{id: id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp required_field(map, key, cast) do
    case Map.fetch(map, key) do
      {:ok, nil} -> error({:missing_field, key})
      {:ok, value} -> cast_field(value, key, cast)
      :error -> error({:missing_field, key})
    end
  end

  defp optional_field(map, key, cast) do
    case map[key] do
      nil -> {:ok, nil}
      value -> cast_field(value, key, cast)
    end
  end

  defp cast_field(value, key, cast) do
    case cast.(value) do
      {:ok, cast_value} -> {:ok, cast_value}
      :error -> error({:invalid_field, key})
    end
  end

  defp cast_string(value) when is_binary(value) and value != "", do: {:ok, value}
  defp cast_string(_value), do: :error

  defp cast_amount(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp cast_amount(_value), do: :error

  defp cast_map(value) when is_map(value), do: {:ok, value}
  defp cast_map(_value), do: :error

  defp cast_currency(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z]{3}\z/, do: {:ok, String.upcase(value)}, else: :error
  end

  defp cast_currency(_value), do: :error

  defp cast_unix_time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp cast_unix_time(_value), do: :error

  defp error(reason), do: {:error, %Error{reason: reason}}
end
