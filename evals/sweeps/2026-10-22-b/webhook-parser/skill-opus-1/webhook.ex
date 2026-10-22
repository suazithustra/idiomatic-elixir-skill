defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated webhook event.
  """

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct @enforce_keys
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  Data of a `"payment.succeeded"` event. `:amount` is in minor units and
  `:currency` is an upper-case ISO 4217 code.
  """

  alias Payments.Webhook.Fields

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, Fields.reason()}
  def from_data(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency"),
         {:ok, customer_email} <- Fields.optional_string(data, "customer_email") do
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
  @moduledoc """
  Data of a `"payment.failed"` event. `:amount` is in minor units and
  `:currency` is an upper-case ISO 4217 code.
  """

  alias Payments.Webhook.Fields

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, Fields.reason()}
  def from_data(data) do
    with {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency"),
         {:ok, customer_email} <- Fields.optional_string(data, "customer_email"),
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
  @moduledoc """
  Data of a `"refund.created"` event. `:amount` is in minor units and
  `:currency` is an upper-case ISO 4217 code.
  """

  alias Payments.Webhook.Fields

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

  @doc false
  @spec from_data(map()) :: {:ok, t()} | {:error, Fields.reason()}
  def from_data(data) do
    with {:ok, refund_id} <- Fields.string(data, "refund_id"),
         {:ok, payment_id} <- Fields.string(data, "payment_id"),
         {:ok, amount} <- Fields.amount(data, "amount"),
         {:ok, currency} <- Fields.currency(data, "currency") do
      {:ok,
       %__MODULE__{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end
end

defmodule Payments.Webhook.ParseError do
  @moduledoc """
  Returned (or raised by `Payments.Webhook.parse!/1`) when a payload cannot be
  parsed. `:reason` is one of:

    * `{:missing_field, key}` - the key is absent or `nil`
    * `{:invalid_field, key}` - the value has the wrong type or format
    * `{:unsupported_event, type}` - the event type is not one we handle
  """

  @type t :: %__MODULE__{reason: Payments.Webhook.Fields.reason()}

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: {:missing_field, key}}),
    do: "webhook payload is missing field #{inspect(key)}"

  def message(%__MODULE__{reason: {:invalid_field, key}}),
    do: "webhook payload has invalid field #{inspect(key)}"

  def message(%__MODULE__{reason: {:unsupported_event, type}}),
    do: "unsupported webhook event type #{inspect(type)}"
end

defmodule Payments.Webhook.Fields do
  @moduledoc false

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @spec string(map(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def string(map, key) do
    case map do
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  @spec optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, reason()}
  def optional_string(map, key) do
    case map do
      %{^key => value} when is_binary(value) or is_nil(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:ok, nil}
    end
  end

  @spec map(map(), String.t()) :: {:ok, map()} | {:error, reason()}
  def map(map, key) do
    case map do
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => value} when is_map(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  @spec amount(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, reason()}
  def amount(map, key) do
    case map do
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => value} when is_integer(value) and value >= 0 -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  @spec currency(map(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def currency(map, key) do
    case string(map, key) do
      {:ok, code} -> parse_currency(code, key)
      {:error, _reason} = error -> error
    end
  end

  @spec unix_time(map(), String.t()) :: {:ok, DateTime.t()} | {:error, reason()}
  def unix_time(map, key) do
    case map do
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => value} when is_integer(value) -> from_unix(value, key)
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_currency(code, key) do
    if code =~ ~r/\A[a-zA-Z]{3}\z/ do
      {:ok, String.upcase(code)}
    else
      {:error, {:invalid_field, key}}
    end
  end

  defp from_unix(seconds, key) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Payloads arrive as string-keyed maps (decoded JSON). `parse/1` validates the
  envelope and the event data and returns a `Payments.Webhook.Event` whose
  `:data` is one of:

    * `Payments.Webhook.PaymentSucceeded` for `"payment.succeeded"`
    * `Payments.Webhook.PaymentFailed` for `"payment.failed"`
    * `Payments.Webhook.RefundCreated` for `"refund.created"`

  Any other event type returns
  `{:error, %Payments.Webhook.ParseError{reason: {:unsupported_event, type}}}`,
  so callers can acknowledge events they do not handle.
  """

  alias Payments.Webhook.{
    Event,
    Fields,
    ParseError,
    PaymentFailed,
    PaymentSucceeded,
    RefundCreated
  }

  @doc """
  Parses a decoded webhook payload.

  ## Examples

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_123",
      ...>     "type" => "payment.succeeded",
      ...>     "created" => 1727000000,
      ...>     "data" => %{
      ...>       "payment_id" => "pay_9",
      ...>       "amount" => 1250,
      ...>       "currency" => "eur",
      ...>       "customer_email" => "a@example.com",
      ...>       "failure_reason" => nil
      ...>     }
      ...>   })
      iex> event.type
      :payment_succeeded
      iex> event.data.amount
      1250
      iex> event.data.currency
      "EUR"

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_124",
      ...>   "type" => "customer.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{}
      ...> })
      {:error, %Payments.Webhook.ParseError{reason: {:unsupported_event, "customer.created"}}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, ParseError.t()}
  def parse(payload) when is_map(payload) do
    case parse_event(payload) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, %ParseError{reason: reason}}
    end
  end

  @doc """
  Like `parse/1`, but returns the event or raises `Payments.Webhook.ParseError`.
  """
  @spec parse!(map()) :: Event.t()
  def parse!(payload) when is_map(payload) do
    case parse(payload) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

  defp parse_event(payload) do
    with {:ok, id} <- Fields.string(payload, "id"),
         {:ok, type_name} <- Fields.string(payload, "type"),
         {:ok, type} <- parse_type(type_name),
         {:ok, created_at} <- Fields.unix_time(payload, "created"),
         {:ok, data} <- Fields.map(payload, "data"),
         {:ok, event_data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: event_data}}
    end
  end

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type_name), do: {:error, {:unsupported_event, type_name}}

  defp parse_data(:payment_succeeded, data), do: PaymentSucceeded.from_data(data)
  defp parse_data(:payment_failed, data), do: PaymentFailed.from_data(data)
  defp parse_data(:refund_created, data), do: RefundCreated.from_data(data)
end
