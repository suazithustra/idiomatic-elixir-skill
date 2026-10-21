defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment reported by the payment provider.

  `amount` is in integer minor units (cents for EUR). `currency` is an
  upper-case ISO 4217 code such as `"EUR"`. `failure_reason` is `nil` unless
  the provider sent one, which it does for failed payments.
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
  A refund of a payment.

  `amount` and `currency` follow the same rules as in `Payments.Webhook.Payment`.
  """

  @enforce_keys [:id, :payment_id, :amount, :currency]
  defstruct [:id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `type` tells which struct `data` holds:

    * `:payment_succeeded` and `:payment_failed` - a `Payments.Webhook.Payment`
    * `:refund_created` - a `Payments.Webhook.Refund`
  """

  alias Payments.Webhook.{Payment, Refund}

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created
  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook.Error do
  @moduledoc """
  The reason a webhook payload could not be parsed.

  `reason` is one of:

    * `{:unsupported_event, type}` - the event type is not one we handle
    * `{:missing_field, key}` - a required field is absent or `null`
    * `{:invalid_field, key}` - a field has the wrong type or format
  """

  @enforce_keys [:reason]
  defexception [:reason]

  @type reason ::
          {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
  @type t :: %__MODULE__{reason: reason()}

  @impl true
  def message(%__MODULE__{reason: {:unsupported_event, type}}),
    do: "unsupported webhook event type #{inspect(type)}"

  def message(%__MODULE__{reason: {:missing_field, key}}),
    do: "webhook payload is missing required field #{inspect(key)}"

  def message(%__MODULE__{reason: {:invalid_field, key}}),
    do: "webhook payload has an invalid value for field #{inspect(key)}"
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses webhook payloads from the payment provider into
  `Payments.Webhook.Event` structs.

  Payloads arrive as JSON already decoded into string-keyed maps. They are
  validated and converted here, once, so the rest of the app works with
  structs and atoms.
  """

  alias Payments.Webhook.{Error, Event, Payment, Refund}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:ok, event}` for a supported event type and
  `{:error, %Payments.Webhook.Error{}}` otherwise. An error with reason
  `{:unsupported_event, type}` means the payload is an event we do not handle,
  which the provider usually expects us to acknowledge anyway. Any other
  reason means the payload is malformed. See `Payments.Webhook.Error`.

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
      iex> event.type
      :payment_succeeded
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

      iex> Payments.Webhook.parse(%{"id" => "evt_124", "type" => "customer.created"})
      {:error, %Payments.Webhook.Error{reason: {:unsupported_event, "customer.created"}}}

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_125",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "amount" => 500, "currency" => "eur"}
      ...> })
      {:error, %Payments.Webhook.Error{reason: {:missing_field, "payment_id"}}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, Error.t()}
  def parse(payload) when is_map(payload) do
    with {:ok, type_name} <- string_field(payload, "type"),
         {:ok, type} <- parse_type(type_name),
         {:ok, id} <- string_field(payload, "id"),
         {:ok, created_at} <- timestamp_field(payload, "created"),
         {:ok, raw_data} <- map_field(payload, "data"),
         {:ok, data} <- parse_data(type, raw_data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, %Error{reason: {:unsupported_event, type}}}

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed],
    do: parse_payment(data)

  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      {:ok,
       %Payment{
         id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency") do
      {:ok, %Refund{id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> missing_field(key)
      _other -> invalid_field(key)
    end
  end

  defp optional_string_field(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> invalid_field(key)
    end
  end

  defp amount_field(map, key) do
    case Map.get(map, key) do
      amount when is_integer(amount) and amount >= 0 -> {:ok, amount}
      nil -> missing_field(key)
      _other -> invalid_field(key)
    end
  end

  defp currency_field(map, key) do
    case Map.get(map, key) do
      currency when is_binary(currency) -> currency_code(currency, key)
      nil -> missing_field(key)
      _other -> invalid_field(key)
    end
  end

  defp currency_code(currency, key) do
    if currency =~ ~r/\A[a-zA-Z]{3}\z/ do
      {:ok, String.upcase(currency)}
    else
      invalid_field(key)
    end
  end

  defp timestamp_field(map, key) do
    case Map.get(map, key) do
      seconds when is_integer(seconds) -> unix_to_datetime(seconds, key)
      nil -> missing_field(key)
      _other -> invalid_field(key)
    end
  end

  defp unix_to_datetime(seconds, key) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> invalid_field(key)
    end
  end

  defp map_field(map, key) do
    case Map.get(map, key) do
      %{} = value -> {:ok, value}
      nil -> missing_field(key)
      _other -> invalid_field(key)
    end
  end

  defp missing_field(key), do: {:error, %Error{reason: {:missing_field, key}}}
  defp invalid_field(key), do: {:error, %Error{reason: {:invalid_field, key}}}
end
