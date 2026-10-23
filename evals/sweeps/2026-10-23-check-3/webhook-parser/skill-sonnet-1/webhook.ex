defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.
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
  Refund details carried by `refund.created` events.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer() | nil,
          currency: String.t() | nil
        }
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated webhook event.
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
  Turns a decoded payment-provider webhook payload into an
  `Payments.Webhook.Event`.

  Amounts are integer minor units (1250 is 12.50 in a currency with two
  decimal places) and are never converted.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed payload.

  Returns `{:error, :invalid_payload}` when the envelope (`"id"`, `"type"`,
  `"created"`, `"data"`) is missing or malformed, `{:error, {:unsupported_event, type}}`
  for an event type the app does not handle, and `{:error, {:missing_field, key}}`
  or `{:error, {:invalid_field, key}}` for a bad field inside `"data"` or `"created"`.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.refund_id, event.data.payment_id}
      {:refund_created, "re_1", "pay_9"}

      iex> Payments.Webhook.parse(%{"id" => "evt_2", "type" => "customer.created", "created" => 1, "data" => %{}})
      {:error, {:unsupported_event, "customer.created"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_3"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, event_type} <- parse_type(type),
         {:ok, occurred_at} <- parse_created(created),
         {:ok, event_data} <- parse_data(event_type, data) do
      {:ok, %Event{id: id, type: event_type, occurred_at: occurred_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(type), do: {:error, {:unsupported_event, type}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(:refund_created, data), do: parse_refund(data)
  defp parse_data(_payment_type, data), do: parse_payment(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- optional_string_field(data, "failure_reason") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: String.upcase(currency),
        customer_email: customer_email,
        failure_reason: failure_reason
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_amount_field(data, "amount"),
         {:ok, currency} <- optional_string_field(data, "currency") do
      refund = %Refund{
        refund_id: refund_id,
        payment_id: payment_id,
        amount: amount,
        currency: currency && String.upcase(currency)
      }

      {:ok, refund}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_amount_field(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end
end
