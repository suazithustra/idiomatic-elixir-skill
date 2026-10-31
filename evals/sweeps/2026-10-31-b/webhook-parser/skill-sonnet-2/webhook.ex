defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units (cents for EUR).
  """

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
  @moduledoc """
  The refund details carried by a `refund.created` event.

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
  A parsed webhook event.
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

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Amounts are integer minor units.
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

  Returns `{:error, :invalid_payload}` when the envelope (`"id"`, `"type"`,
  `"created"`, `"data"`) is missing or malformed, `{:error, {:unsupported_event, type}}`
  for an event type we do not handle, and `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when the event's data is wrong.

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
      iex> {event.type, event.data.amount, event.created_at}
      {:payment_succeeded, 1250, ~U[2024-09-22 10:13:20Z]}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
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

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} ->
        {:ok, created_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(:succeeded, data)
  defp parse_data(:payment_failed, data), do: parse_payment(:failed, data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(status, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
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
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency") do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
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
      {:ok, amount} when is_integer(amount) and amount >= 0 ->
        {:ok, amount}

      {:ok, _amount} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
