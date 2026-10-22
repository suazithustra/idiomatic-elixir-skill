defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc """
  Data of a `payment.succeeded` event. `amount` is in minor units of `currency`.
  """

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc """
  Data of a `payment.failed` event. `amount` is in minor units of `currency`.
  """

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc """
  Data of a `refund.created` event. `amount` is in minor units of `currency`.
  """

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event: the envelope fields plus the type-specific `data`.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          occurred_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook.Error do
  @moduledoc """
  The reason a webhook payload could not be parsed.

  `reason` is one of:

    * `{:missing_field, key}` - a required field is absent or `nil`
    * `{:invalid_field, key}` - a field has the wrong type or format
    * `{:unsupported_event, type}` - the event type is not one we handle
  """

  defexception [:reason]

  @type reason ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @type t :: %__MODULE__{reason: reason()}

  @impl true
  def message(%__MODULE__{reason: {:missing_field, key}}) do
    "webhook payload is missing required field #{inspect(key)}"
  end

  def message(%__MODULE__{reason: {:invalid_field, key}}) do
    "webhook payload has an invalid value for field #{inspect(key)}"
  end

  def message(%__MODULE__{reason: {:unsupported_event, type}}) do
    "unsupported webhook event type #{inspect(type)}"
  end
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded payment provider webhook payloads (string-keyed maps) into
  `Payments.Webhook.Event` structs.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Amounts stay integer minor units; currencies are
  normalized to upper-case ISO 4217 codes such as `"EUR"`.
  """

  alias Payments.Webhook.{Error, Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, %Payments.Webhook.Error{}}` when a field is missing or
  invalid, or when the event type is not supported. Callers that acknowledge
  unknown events can match on `{:unsupported_event, type}` in the reason.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9", "amount" => 500, "currency" => "eur"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.amount, event.data.currency}
      {:refund_created, 500, "EUR"}

      iex> Payments.Webhook.parse(%{"id" => "evt_2", "type" => "customer.created", "created" => 0, "data" => %{}})
      {:error, %Payments.Webhook.Error{reason: {:unsupported_event, "customer.created"}}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, Error.t()}
  def parse(payload) when is_map(payload) do
    case parse_event(payload) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, %Error{reason: reason}}
    end
  end

  @doc """
  Like `parse/1`, but returns the event directly and raises
  `Payments.Webhook.Error` on failure.
  """
  @spec parse!(map()) :: Event.t()
  def parse!(payload) when is_map(payload) do
    case parse(payload) do
      {:ok, event} -> event
      {:error, error} -> raise error
    end
  end

  defp parse_event(payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type_name} <- string_field(payload, "type"),
         {:ok, type} <- parse_type(type_name),
         {:ok, occurred_at} <- timestamp_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, parsed_data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, data: parsed_data}}
    end
  end

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type_name), do: {:error, {:unsupported_event, type_name}}

  defp parse_data(:payment_succeeded, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email") do
      payment = %PaymentSucceeded{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, payment}
    end
  end

  defp parse_data(:payment_failed, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      payment = %PaymentFailed{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency") do
      refund = %RefundCreated{
        refund_id: refund_id,
        payment_id: payment_id,
        amount: amount,
        currency: currency
      }

      {:ok, refund}
    end
  end

  defp string_field(map, key) do
    case map do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case map do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => nil} -> {:ok, nil}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:ok, nil}
    end
  end

  defp map_field(map, key) do
    case map do
      %{^key => value} when is_map(value) -> {:ok, value}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case map do
      %{^key => amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _amount} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp timestamp_field(map, key) do
    case map do
      %{^key => unix_seconds} when is_integer(unix_seconds) -> parse_unix(unix_seconds, key)
      %{^key => nil} -> {:error, {:missing_field, key}}
      %{^key => _unix_seconds} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_unix(unix_seconds, key) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end

  defp currency_field(map, key) do
    case string_field(map, key) do
      {:ok, code} -> parse_currency(code, key)
      {:error, _reason} = error -> error
    end
  end

  defp parse_currency(code, key) do
    if code =~ ~r/\A[a-zA-Z]{3}\z/ do
      {:ok, String.upcase(code)}
    else
      {:error, {:invalid_field, key}}
    end
  end
end
