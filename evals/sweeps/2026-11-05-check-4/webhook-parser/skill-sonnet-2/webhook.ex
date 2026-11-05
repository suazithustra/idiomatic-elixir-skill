defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is in integer minor units (cents for `"eur"`).
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
  Refund details carried by `refund.created` events.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event.

  `data` is a `Payments.Webhook.Payment` for `:payment_succeeded` and
  `:payment_failed`, and a `Payments.Webhook.Refund` for `:refund_created`.
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
  Turns a decoded payment-provider webhook payload into a `Payments.Webhook.Event`.

  The payload is a map with string keys, as produced by a JSON decoder.
  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type reason ::
          :invalid_payload
          | {:invalid_field, String.t()}
          | {:missing_field, String.t()}
          | {:unsupported_event, term()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:error, {:unsupported_event, type}}` for an event type the app
  does not handle, so the caller can acknowledge it without acting on it.
  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  when a field of a supported event is absent or has the wrong shape.

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
      iex> event.data.amount
      1250

      iex> unknown = %{"id" => "evt_1", "type" => "invoice.paid", "created" => 1727000000, "data" => %{}}
      iex> Payments.Webhook.parse(unknown)
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, reason()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data}) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, event_id} <- non_empty_string(id, "id"),
         {:ok, created_at} <- parse_created(created),
         {:ok, event_data} <- parse_data(event_type, data) do
      {:ok, %Event{id: event_id, type: event_type, created_at: created_at, data: event_data}}
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

  defp parse_data(:refund_created, %{} = data) do
    with {:ok, refund_id} <- required_string(data, "refund_id"),
         {:ok, payment_id} <- required_string(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_data(_payment_type, %{} = data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- required_amount(data, "amount"),
         {:ok, currency} <- required_string(data, "currency"),
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

  defp parse_data(_type, _data), do: {:error, {:invalid_field, "data"}}

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_string(_value, field), do: {:error, {:invalid_field, field}}

  defp required_string(map, field) do
    case map do
      %{^field => value} ->
        non_empty_string(value, field)

      %{} ->
        {:error, {:missing_field, field}}
    end
  end

  defp required_amount(map, field) do
    case map do
      %{^field => amount} when is_integer(amount) and amount >= 0 ->
        {:ok, amount}

      %{^field => _amount} ->
        {:error, {:invalid_field, field}}

      %{} ->
        {:error, {:missing_field, field}}
    end
  end

  defp optional_string(map, field) do
    case map do
      %{^field => nil} ->
        {:ok, nil}

      %{^field => value} ->
        non_empty_string(value, field)

      %{} ->
        {:ok, nil}
    end
  end
end
