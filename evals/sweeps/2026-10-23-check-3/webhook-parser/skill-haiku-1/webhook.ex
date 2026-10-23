defmodule Payments.Webhook.Payment do
  @moduledoc """
  The data of a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units, such as cents.
  """

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The data of a `refund.created` event. A refund points at the payment it reverses.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is a `Payments.Webhook.Payment` for payment
  events and a `Payments.Webhook.Refund` for refund events.
  """

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          created_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload into a `Payments.Webhook.Event`.

  The payload is a map with string keys, as a JSON decoder returns it. Amounts
  stay in integer minor units (cents), so the rest of the app never handles floats.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @event_types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @doc """
  Parses a webhook payload.

  Errors:

    * `{:error, {:unsupported_event, type}}` when the app does not handle the event type
    * `{:error, {:missing_field, key}}` when a required field is absent
    * `{:error, {:invalid_field, key}}` when a field has the wrong type
    * `{:error, :invalid_payload}` when the payload has no string `"type"`

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.data
      %Payments.Webhook.Refund{refund_id: "re_1", payment_id: "pay_9"}

      iex> Payments.Webhook.parse(%{"id" => "evt_2", "type" => "customer.created"})
      {:error, {:unsupported_event, "customer.created"}}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"type" => type} = payload) when is_binary(type) do
    # The type is checked before the other fields: an event we do not handle
    # may carry any shape, so its missing fields are not an error.
    with {:ok, event_type} <- event_type(type),
         {:ok, id} <- checked_field(payload, "id", &is_binary/1),
         {:ok, created} <- checked_field(payload, "created", &is_integer/1),
         {:ok, created_at} <- unix_datetime(created),
         {:ok, data} <- checked_field(payload, "data", &is_map/1),
         {:ok, event_data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_type(type) do
    case Map.fetch(@event_types, type) do
      {:ok, event_type} -> {:ok, event_type}
      :error -> {:error, {:unsupported_event, type}}
    end
  end

  defp checked_field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp unix_datetime(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_data(:payment_succeeded, data), do: payment_data(data)
  defp parse_data(:payment_failed, data), do: payment_data(data)
  defp parse_data(:refund_created, data), do: refund_data(data)

  defp payment_data(data) do
    with {:ok, payment_id} <- checked_field(data, "payment_id", &is_binary/1),
         {:ok, amount} <- checked_field(data, "amount", &is_integer/1),
         {:ok, currency} <- checked_field(data, "currency", &is_binary/1),
         {:ok, customer_email} <- optional_string(data, "customer_email"),
         {:ok, failure_reason} <- optional_string(data, "failure_reason") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp refund_data(data) do
    with {:ok, refund_id} <- checked_field(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- checked_field(data, "payment_id", &is_binary/1) do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end
end
