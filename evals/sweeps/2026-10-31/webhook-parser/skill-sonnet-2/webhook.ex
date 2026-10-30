defmodule Payments.Webhook.Payment do
  @moduledoc """
  The data of a `payment.succeeded` or `payment.failed` event.

  `amount` is in minor units (cents). `currency` is an upper-case ISO 4217 code.
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
  The data of a `refund.created` event.
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
  A verified-shape webhook event from the payment provider.
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
  Turns a decoded webhook payload into an `Payments.Webhook.Event`.

  The payload is a map with string keys, as decoded from the provider's JSON.
  Only `payment.succeeded`, `payment.failed` and `refund.created` are supported.
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
  Parses a decoded webhook payload.

  Returns `{:error, :invalid_payload}` when the envelope (`"id"`, `"type"`,
  `"created"`, `"data"`) is missing or has the wrong shape,
  `{:error, {:unsupported_event, type}}` for an event type we do not handle, and
  `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}` when a
  field of the event's data is absent or malformed.

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

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "invoice.paid", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "invoice.paid"}}

      iex> Payments.Webhook.parse(%{"foo" => "bar"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, kind} <- parse_type(type),
         {:ok, created_at} <- parse_created(created),
         {:ok, event_data} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} ->
        {:ok, created_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- currency_field(data, "currency") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: data["customer_email"],
        failure_reason: data["failure_reason"]
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
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

  defp currency_field(data, key) do
    with {:ok, code} <- string_field(data, key) do
      currency(code, key)
    end
  end

  defp currency(code, _key) when byte_size(code) == 3, do: {:ok, String.upcase(code)}
  defp currency(_code, key), do: {:error, {:invalid_field, key}}
end
