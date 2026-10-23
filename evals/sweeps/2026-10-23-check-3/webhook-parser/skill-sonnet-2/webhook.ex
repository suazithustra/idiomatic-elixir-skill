defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is in integer minor units (cents). `failure_reason` is `nil`
  unless the payment failed.
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
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A validated webhook event.

  `data` is a `Payments.Webhook.Payment` for the payment event types and a
  `Payments.Webhook.Refund` for `:refund_created`.
  """

  alias Payments.Webhook.{Payment, Refund}

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
  Turns a decoded payment provider webhook payload into an
  `Payments.Webhook.Event`.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type is rejected with
  `{:error, {:unsupported_event, type}}`, so the caller can decide whether
  to acknowledge it anyway.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a string-keyed payload into an event.

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

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "charge.disputed", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "charge.disputed"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, type} <- parse_type(type),
         {:ok, created_at} <- parse_created(created),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
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

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)

  defp parse_data(:payment_failed, data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, _reason} <- string_field(data, "failure_reason") do
      {:ok, payment}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

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

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
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

  defp amount_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
