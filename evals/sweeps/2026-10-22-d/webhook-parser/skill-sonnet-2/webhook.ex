defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by a `:payment_succeeded` or `:payment_failed` event.

  `amount` is in integer minor units (cents for `"eur"`).
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund details carried by a `:refund_created` event.

  `amount` is in integer minor units.
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
  A validated webhook event.
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
  Turns payment provider webhook payloads into `Payments.Webhook.Event` structs.

  Payloads are JSON already decoded into string-keyed maps. Supported event
  types are `payment.succeeded`, `payment.failed` and `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          {:invalid_payload, term()}
          | {:unsupported_event, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:unsupported_event, type}}` for an event type we do not
  handle, and `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first required field that is absent or has the wrong shape.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{
      ...>     "refund_id" => "re_1",
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 500,
      ...>     "currency" => "eur"
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.refund_id, event.data.amount}
      {:refund_created, "re_1", 500}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created"})
      {:error, {:unsupported_event, "customer.created"}}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, event_type} <- event_type(type),
         {:ok, created_at} <- timestamp_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, details} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: details}}
    end
  end

  def parse(other), do: {:error, {:invalid_payload, other}}

  defp event_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_type("payment.failed"), do: {:ok, :payment_failed}
  defp event_type("refund.created"), do: {:ok, :refund_created}
  defp event_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency") do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp parse_data(_payment_event_type, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
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
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:ok, nil}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp timestamp_field(map, key) do
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

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
