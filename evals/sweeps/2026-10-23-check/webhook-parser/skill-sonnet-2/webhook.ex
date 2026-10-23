defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment details carried by a `:payment_succeeded` or `:payment_failed` event.

  `amount` is in minor units (1250 is 12.50). `failure_reason` is `nil` unless
  the payment failed.
  """

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: pos_integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  The refund details carried by a `:refund_created` event.

  `amount` and `currency` are `nil` when the provider does not send them.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: pos_integer() | nil,
          currency: String.t() | nil
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
  Turns a decoded webhook payload from the payment provider into an
  `Payments.Webhook.Event`.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Amounts are integers in minor units.
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
  Parses a string-keyed payload into an event.

  Returns `{:error, :invalid_payload}` when the envelope keys (`"id"`, `"type"`,
  `"created"`, `"data"`) are missing, `{:error, {:unsupported_event, type}}` for
  an event type we do not handle, and `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when a field of `"data"` or the envelope
  cannot be used.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.data.refund_id}
      {:refund_created, "re_1"}

      iex> Payments.Webhook.parse(%{"type" => "payment.succeeded"})
      {:error, :invalid_payload}

      iex> payload = %{"id" => "evt_2", "type" => "invoice.paid", "created" => 1727000000, "data" => %{}}
      iex> Payments.Webhook.parse(payload)
      {:error, {:unsupported_event, "invoice.paid"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, type} <- parse_type(type),
         {:ok, created_at} <- parse_created(created),
         {:ok, details} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: details}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
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

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- optional_amount_field(data, "amount"),
         {:ok, currency} <- optional_string_field(data, "currency") do
      {:ok,
       %Refund{
         refund_id: refund_id,
         payment_id: payment_id,
         amount: amount,
         currency: currency
       }}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _value} -> string_field(data, key)
    end
  end

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, nil} -> {:ok, nil}
      :error -> {:ok, nil}
      {:ok, _value} -> amount_field(data, key)
    end
  end
end
