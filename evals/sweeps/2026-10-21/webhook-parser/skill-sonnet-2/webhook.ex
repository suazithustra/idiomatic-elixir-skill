defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is in minor units and `currency` is an upper-case ISO 4217 code.
  """

  @derive {Inspect, except: [:customer_email]}
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

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Refund details carried by `refund.created` events.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `data` is a `Payments.Webhook.Payment` for `:payment_succeeded` and `:payment_failed`,
  and a `Payments.Webhook.Refund` for `:refund_created`.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type type :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          occurred_at: DateTime.t(),
          data: Payment.t() | Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded payment-provider webhook payloads into `Payments.Webhook.Event` structs.

  Supported event types are `payment.succeeded`, `payment.failed` and `refund.created`.
  Amounts are integer minor units (for example cents).

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
      iex> {event.type, event.data.amount, event.data.currency}
      {:payment_succeeded, 1250, "EUR"}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 0, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "refund.created", "created" => 0, "data" => %{"refund_id" => "re_1"}})
      {:error, {:missing_field, "payment_id"}}
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}` naming the
  first field that failed validation, and `{:error, {:unsupported_event, type}}` for event
  types the app does not handle.
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- fetch_string(payload, "id"),
         {:ok, type} <- fetch_string(payload, "type"),
         {:ok, event_type} <- parse_type(type),
         {:ok, occurred_at} <- fetch_timestamp(payload, "created"),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, details} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, data: details}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_data(:refund_created, data), do: parse_refund(data)
  defp parse_data(_payment_event, data), do: parse_payment(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_string(data, "currency"),
         {:ok, customer_email} <- fetch_optional_string(data, "customer_email"),
         {:ok, failure_reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: String.upcase(currency),
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
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_amount(map, key) do
    case Map.fetch(map, key) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_timestamp(map, key) do
    case Map.fetch(map, key) do
      {:ok, seconds} when is_integer(seconds) -> from_unix(seconds, key)
      {:ok, _seconds} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp from_unix(seconds, key) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end
end
