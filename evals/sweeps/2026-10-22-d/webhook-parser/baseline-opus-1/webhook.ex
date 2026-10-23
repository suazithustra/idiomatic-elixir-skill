defmodule Payments.Webhook.Fields do
  @moduledoc false
  # Validating field accessors shared by the webhook parser and event data modules.

  @spec fetch_string(map(), String.t()) ::
          {:ok, String.t()} | {:error, Payments.Webhook.error_reason()}
  def fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @spec fetch_optional_string(map(), String.t()) ::
          {:ok, String.t() | nil} | {:error, Payments.Webhook.error_reason()}
  def fetch_optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @spec fetch_amount(map(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, Payments.Webhook.error_reason()}
  def fetch_amount(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @spec fetch_currency(map(), String.t()) ::
          {:ok, String.t()} | {:error, Payments.Webhook.error_reason()}
  def fetch_currency(map, key) do
    with {:ok, value} <- fetch_string(map, key) do
      if value =~ ~r/\A[a-zA-Z]{3}\z/ do
        {:ok, String.upcase(value)}
      else
        {:error, {:invalid_field, key, value}}
      end
    end
  end

  @spec fetch_timestamp(map(), String.t()) ::
          {:ok, DateTime.t()} | {:error, Payments.Webhook.error_reason()}
  def fetch_timestamp(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) ->
        case DateTime.from_unix(value) do
          {:ok, datetime} -> {:ok, datetime}
          {:error, _} -> {:error, {:invalid_field, key, value}}
        end

      {:ok, nil} ->
        {:error, {:missing_field, key}}

      {:ok, value} ->
        {:error, {:invalid_field, key, value}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data for a `payment.succeeded` event."

  import Payments.Webhook.Fields

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, Payments.Webhook.error_reason()}
  def from_map(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, customer_email} <- fetch_optional_string(data, "customer_email") do
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
  @moduledoc "Data for a `payment.failed` event."

  import Payments.Webhook.Fields

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
  @spec from_map(map()) :: {:ok, t()} | {:error, Payments.Webhook.error_reason()}
  def from_map(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, customer_email} <- fetch_optional_string(data, "customer_email"),
         {:ok, failure_reason} <- fetch_optional_string(data, "failure_reason") do
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
  @moduledoc "Data for a `refund.created` event."

  import Payments.Webhook.Fields

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, Payments.Webhook.error_reason()}
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
  @moduledoc "A parsed webhook event envelope."

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct @enforce_keys

  @type event_type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: event_type(),
          created_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Payloads arrive as maps with string keys. `parse/1` validates the envelope
  and the event-specific data, returning a `Payments.Webhook.Event` whose
  `:data` field holds one of the event data structs:

    * `Payments.Webhook.PaymentSucceeded`
    * `Payments.Webhook.PaymentFailed`
    * `Payments.Webhook.RefundCreated`

  Amounts stay as integer minor units; currencies are normalised to
  upper-case ISO 4217 codes (`"eur"` becomes `"EUR"`).

  Event types not listed above return `{:error, {:unsupported_event_type, type}}`
  so callers can acknowledge and skip them.
  """

  import Payments.Webhook.Fields, only: [fetch_string: 2, fetch_timestamp: 2]

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type error_reason ::
          :invalid_payload
          | {:unsupported_event_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @event_types %{
    "payment.succeeded" => {:payment_succeeded, PaymentSucceeded},
    "payment.failed" => {:payment_failed, PaymentFailed},
    "refund.created" => {:refund_created, RefundCreated}
  }

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

      iex> Payments.Webhook.parse(%{"id" => "evt_2", "type" => "customer.created", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event_type, "customer.created"}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error_reason()}
  def parse(%{"type" => type, "data" => data} = payload) when is_map(data) do
    with {:ok, {event_type, module}} <- fetch_event_type(type),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, event_data} <- module.from_map(data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp fetch_event_type(type) do
    case Map.fetch(@event_types, type) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unsupported_event_type, type}}
    end
  end
end
