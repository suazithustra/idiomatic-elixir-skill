defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is in integer minor units (for example cents).
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
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A webhook event from the payment provider, after parsing and validation.

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
  Turns a decoded webhook payload from the payment provider into an
  `Payments.Webhook.Event`.

  The payload is a map with string keys, as produced by a JSON decoder. The
  supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error_reason ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, :invalid_payload}` when the payload lacks the envelope keys
  `"id"`, `"type"`, `"created"` and `"data"`, `{:error, {:unsupported_event, type}}`
  for an event type the application does not handle, and
  `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}` when a
  field of the event data is absent or has the wrong type.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.type
      :refund_created
      iex> event.data.refund_id
      "re_1"

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "payout.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "payout.paid"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error_reason()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, created_at} <- parse_created(created),
         {:ok, event_data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) do
    case is_integer(created) and DateTime.from_unix(created) do
      {:ok, created_at} ->
        {:ok, created_at}

      _invalid ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_data(_payment_type, data) do
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

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) or is_nil(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:ok, nil}
    end
  end

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
