defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is an integer in minor units (cents for EUR).
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

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund details carried by `refund.created` events.

  `amount` is an integer in minor units, or `nil` when the provider did not send one.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated webhook event.

  `data` is a `Payments.Webhook.Payment` for payment events and a
  `Payments.Webhook.Refund` for refund events.
  """

  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

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

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into
  `Payments.Webhook.Event` structs.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed payload into an event.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  naming the first field that failed validation, and
  `{:error, {:unsupported_event, type}}` for event types the app ignores.

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
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.created_at, event.data.amount}
      {:payment_succeeded, ~U[2024-09-22 10:13:20Z], 1250}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 0, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "refund.created", "created" => 0, "data" => %{}})
      {:error, {:missing_field, "refund_id"}}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, event_type} <- event_type(type),
         {:ok, created_at} <- datetime_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, parsed_data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: parsed_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_data(event_type, data) when event_type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email,
         failure_reason: failure_reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_amount_field(data, "amount") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount}}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _value} -> string_field(map, key)
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _value} -> amount_field(map, key)
    end
  end

  defp datetime_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, seconds} when is_integer(seconds) -> from_unix(seconds, key)
      {:ok, _value} -> {:error, {:invalid_field, key}}
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
