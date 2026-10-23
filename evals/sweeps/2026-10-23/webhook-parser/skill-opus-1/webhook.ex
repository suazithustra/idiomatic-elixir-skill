defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment a `:payment_succeeded` or `:payment_failed` event refers to.

  `amount` is in minor units of `currency` (cents for `"EUR"`). `customer_email`
  and `failure_reason` are `nil` when the provider does not send them.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @enforce_keys [:id, :amount, :currency]
  defstruct [:id, :amount, :currency, :customer_email, :failure_reason]
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund a `:refund_created` event refers to.

  `amount` is in minor units of `currency`, and `payment_id` is the payment
  the refund returns money from.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }

  @enforce_keys [:id, :payment_id, :amount, :currency]
  defstruct [:id, :payment_id, :amount, :currency]
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A webhook event from the payment provider.

  `data` is a `Payments.Webhook.Payment` for `:payment_succeeded` and
  `:payment_failed` events, and a `Payments.Webhook.Refund` for
  `:refund_created` events.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type event_type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: event_type(),
          created_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]
end

defmodule Payments.Webhook.ParseError do
  @moduledoc """
  The reason a webhook payload could not be parsed.

  `reason` is one of:

    * `:invalid_payload` - the payload lacks one of `"id"`, `"type"`,
      `"created"` or `"data"`.
    * `{:unsupported_event, type}` - the event type is not one the app handles.
      Acknowledge such events to the provider instead of treating them as failures.
    * `{:missing_field, key}` - a required field is absent or `nil`.
    * `{:invalid_field, key}` - a field has the wrong type or format.
  """

  @type reason ::
          :invalid_payload
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @type t :: %__MODULE__{reason: reason()}

  @enforce_keys [:reason]
  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: :invalid_payload}) do
    ~s(webhook payload must contain "id", "type", "created" and "data")
  end

  def message(%__MODULE__{reason: {:unsupported_event, type}}) do
    "unsupported webhook event type #{inspect(type)}"
  end

  def message(%__MODULE__{reason: {:missing_field, key}}) do
    "webhook payload is missing field #{inspect(key)}"
  end

  def message(%__MODULE__{reason: {:invalid_field, key}}) do
    "webhook payload has an invalid value for field #{inspect(key)}"
  end
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses payment provider webhook payloads into `Payments.Webhook.Event` structs.

  Payloads arrive as decoded JSON with string keys. `parse/1` checks every
  field the app relies on and converts it: the event type to an atom,
  `"created"` (Unix seconds) to a `DateTime`, the currency to an upper-case
  ISO 4217 code, and `"data"` to a `Payments.Webhook.Payment` or a
  `Payments.Webhook.Refund`.

  | Provider type         | `Event.type`         | `Event.data`               |
  | --------------------- | -------------------- | -------------------------- |
  | `"payment.succeeded"` | `:payment_succeeded` | `Payments.Webhook.Payment` |
  | `"payment.failed"`    | `:payment_failed`    | `Payments.Webhook.Payment` |
  | `"refund.created"`    | `:refund_created`    | `Payments.Webhook.Refund`  |

  This module does not check the webhook signature. Verify it against the raw
  request body before decoding the JSON.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.ParseError
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, %Payments.Webhook.ParseError{}}` when the payload is
  malformed or its event type is not supported; the error's `reason` says which.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1727000000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com",
      ...>     "failure_reason" => nil
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.created_at
      ~U[2024-09-22 10:13:20Z]
      iex> event.data
      %Payments.Webhook.Payment{
        id: "pay_9",
        amount: 1250,
        currency: "EUR",
        customer_email: "a@example.com",
        failure_reason: nil
      }

      iex> payload = %{
      ...>   "id" => "evt_124",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9", "currency" => "eur"}
      ...> }
      iex> Payments.Webhook.parse(payload)
      {:error, %Payments.Webhook.ParseError{reason: {:missing_field, "amount"}}}

      iex> payload = %{"id" => "evt_125", "type" => "payout.paid", "created" => 1727000000, "data" => %{}}
      iex> Payments.Webhook.parse(payload)
      {:error, %Payments.Webhook.ParseError{reason: {:unsupported_event, "payout.paid"}}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, ParseError.t()}
  def parse(payload) when is_map(payload) do
    case parse_event(payload) do
      {:ok, %Event{}} = ok -> ok
      {:error, reason} -> {:error, %ParseError{reason: reason}}
    end
  end

  @doc """
  Parses a decoded webhook payload like `parse/1`, raising
  `Payments.Webhook.ParseError` when it cannot.
  """
  @spec parse!(map()) :: Event.t()
  def parse!(payload) do
    case parse(payload) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

  defp parse_event(%{"id" => id, "type" => type, "created" => created, "data" => data}) do
    with {:ok, id} <- event_id(id),
         {:ok, event_type} <- event_type(type),
         {:ok, created_at} <- created_at(created),
         {:ok, data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: data}}
    end
  end

  defp parse_event(_payload), do: {:error, :invalid_payload}

  defp event_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp event_id(_id), do: {:error, {:invalid_field, "id"}}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(type) when is_binary(type), do: {:error, {:unsupported_event, type}}
  defp event_type(_type), do: {:error, {:invalid_field, "type"}}

  defp created_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp created_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(_event_type, data) when not is_map(data), do: {:error, {:invalid_field, "data"}}
  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
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
    with {:ok, id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency") do
      {:ok, %Refund{id: id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp string_field(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp amount_field(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      _amount -> {:error, {:invalid_field, key}}
    end
  end

  defp currency_field(map, key) do
    case string_field(map, key) do
      {:ok, currency} -> currency_code(currency, key)
      {:error, _reason} = error -> error
    end
  end

  defp currency_code(currency, key) do
    if String.match?(currency, ~r/\A[a-zA-Z]{3}\z/) do
      {:ok, String.upcase(currency)}
    else
      {:error, {:invalid_field, key}}
    end
  end
end
