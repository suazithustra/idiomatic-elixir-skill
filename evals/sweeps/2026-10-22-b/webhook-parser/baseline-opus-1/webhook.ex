defmodule Payments.Webhook.Fields do
  @moduledoc false
  # Validating accessors for string-keyed payload maps. Errors carry the key
  # as given, so callers can report exactly which field was wrong.

  @type error :: {:missing_field, String.t()} | {:invalid_field, String.t(), term()}

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def fetch_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @spec fetch_optional_string(map(), String.t()) :: {:ok, String.t() | nil} | {:error, error()}
  def fetch_optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @spec fetch_amount(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def fetch_amount(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @doc """
  Fetches an ISO 4217 currency code, normalised to upper case (`"eur"` -> `"EUR"`).
  """
  @spec fetch_currency(map(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def fetch_currency(map, key) do
    with {:ok, value} <- fetch_string(map, key) do
      if value =~ ~r/\A[a-zA-Z]{3}\z/ do
        {:ok, String.upcase(value)}
      else
        {:error, {:invalid_field, key, value}}
      end
    end
  end

  @doc """
  Fetches a Unix timestamp in seconds as a UTC `DateTime`.
  """
  @spec fetch_timestamp(map(), String.t()) :: {:ok, DateTime.t()} | {:error, error()}
  def fetch_timestamp(map, key) do
    case Map.get(map, key) do
      nil ->
        {:error, {:missing_field, key}}

      value when is_integer(value) ->
        case DateTime.from_unix(value) do
          {:ok, datetime} -> {:ok, datetime}
          {:error, _} -> {:error, {:invalid_field, key, value}}
        end

      value ->
        {:error, {:invalid_field, key, value}}
    end
  end

  @spec fetch_map(map(), String.t()) :: {:ok, map()} | {:error, error()}
  def fetch_map(map, key) do
    case Map.get(map, key) do
      nil -> {:error, {:missing_field, key}}
      %{} = value -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data for a `payment.succeeded` event."

  import Payments.Webhook.Fields

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, Payments.Webhook.Fields.error()}
  def from_map(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- fetch_optional_string(data, "customer_email") do
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

  import Payments.Webhook.Fields

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
  @spec from_map(map()) :: {:ok, t()} | {:error, Payments.Webhook.Fields.error()}
  def from_map(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- fetch_optional_string(data, "customer_email"),
         {:ok, failure_reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       %__MODULE__{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: failure_reason
       }}
    end
  end
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data for a `refund.created` event."

  import Payments.Webhook.Fields

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, Payments.Webhook.Fields.error()}
  def from_map(data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency") do
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

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `:data` holds the event-specific struct.
  """

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          created_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct @enforce_keys
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Payloads arrive as maps with string keys. `parse/1` validates the envelope
  and the event-specific `"data"` and returns a `Payments.Webhook.Event` whose
  `:data` is one of:

    * `Payments.Webhook.PaymentSucceeded`
    * `Payments.Webhook.PaymentFailed`
    * `Payments.Webhook.RefundCreated`

  Event types are mapped explicitly, so strings from the payload are never
  converted to atoms dynamically. Unknown event types are reported as
  `{:error, {:unsupported_event_type, type}}` so callers can acknowledge and
  ignore them.
  """

  import Payments.Webhook.Fields

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error_reason ::
          :invalid_payload
          | {:unsupported_event_type, String.t()}
          | Payments.Webhook.Fields.error()

  @event_types %{
    "payment.succeeded" => {:payment_succeeded, PaymentSucceeded},
    "payment.failed" => {:payment_failed, PaymentFailed},
    "refund.created" => {:refund_created, RefundCreated}
  }

  @doc """
  Returns the provider event types this module understands.
  """
  @spec supported_types() :: [String.t()]
  def supported_types, do: Map.keys(@event_types)

  @doc """
  Parses a decoded webhook payload.

  ## Examples

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_1", "amount" => 500, "currency" => "eur"}
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :refund_created,
         created_at: ~U[2024-09-22 10:13:20Z],
         data: %Payments.Webhook.RefundCreated{
           refund_id: "re_1",
           payment_id: "pay_1",
           amount: 500,
           currency: "EUR"
         }
       }}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event_type, "customer.created"}}

  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error_reason()}
  def parse(%{} = payload) do
    with {:ok, id} <- fetch_string(payload, "id"),
         {:ok, type_string} <- fetch_string(payload, "type"),
         {:ok, {type, data_module}} <- lookup_type(type_string),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, parsed_data} <- data_module.from_map(data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: parsed_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp lookup_type(type_string) do
    case Map.fetch(@event_types, type_string) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unsupported_event_type, type_string}}
    end
  end
end
