defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `object` is a `Payment` or a `Refund`."

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          object: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc "A payment that succeeded or failed."

  @enforce_keys [:payment_id, :status, :amount, :currency]
  defstruct [:payment_id, :status, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          status: :succeeded | :failed,
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc "A refund created against a payment."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end
defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment provider webhook payload (a map with string keys)
  into a typed `Payments.Webhook.Event`.

  Supported event types:

    * `"payment.succeeded"` -> `%Payments.Webhook.Payment{status: :succeeded}`
    * `"payment.failed"`    -> `%Payments.Webhook.Payment{status: :failed}`
    * `"refund.created"`    -> `%Payments.Webhook.Refund{}`

  Any other type returns `{:error, {:unsupported_type, type}}`, so the caller
  can acknowledge the webhook and skip it.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          {:unsupported_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @event_types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @doc """
  Parses a webhook payload.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_123",
      ...>   "type" => "payment.succeeded",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 1250,
      ...>     "currency" => "eur",
      ...>     "customer_email" => "a@example.com",
      ...>     "failure_reason" => nil
      ...>   }
      ...> }
      iex> {:ok, %Event{type: :payment_succeeded, object: %Payment{amount: 1250}}} =
      ...>   Payments.Webhook.parse(payload)
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- fetch_string(payload, "id"),
         {:ok, type} <- fetch_string(payload, "type"),
         {:ok, event_type} <- fetch_event_type(type),
         {:ok, created} <- fetch_integer(payload, "created"),
         {:ok, occurred_at} <- fetch_timestamp(created),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, object} <- parse_object(event_type, data) do
      {:ok,
       %Event{
         id: id,
         type: event_type,
         occurred_at: occurred_at,
         object: object
       }}
    end
  end

  def parse(other), do: {:error, {:invalid_field, "payload", other}}

  defp fetch_event_type(type) do
    case Map.fetch(@event_types, type) do
      {:ok, event_type} -> {:ok, event_type}
      :error -> {:error, {:unsupported_type, type}}
    end
  end

  defp parse_object(:payment_succeeded, data), do: parse_payment(data, :succeeded)
  defp parse_object(:payment_failed, data), do: parse_payment(data, :failed)
  defp parse_object(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data, status) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, customer_email} <- fetch_optional_string(data, "customer_email"),
         {:ok, failure_reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         status: status,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  defp fetch_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  # Amounts are integer minor units (for example cents), so they cannot be negative.
  defp fetch_amount(map, key) do
    case fetch_integer(map, key) do
      {:ok, value} when value >= 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      error -> error
    end
  end

  # Stored as an upper-case ISO 4217 code, such as "EUR".
  defp fetch_currency(map, key) do
    with {:ok, code} <- fetch_string(map, key) do
      code = String.upcase(code)

      if code =~ ~r/\A[A-Z]{3}\z/ do
        {:ok, code}
      else
        {:error, {:invalid_field, key, code}}
      end
    end
  end

  defp fetch_timestamp(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created", created}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end

