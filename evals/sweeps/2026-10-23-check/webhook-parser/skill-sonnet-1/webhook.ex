defmodule Payments.Webhook.Payment do
  @moduledoc """
  The payment a `payment.succeeded` or `payment.failed` event is about.

  `amount` is in minor units (1250 is 12.50 in a two-decimal currency) and
  `currency` is upper case. `failure_reason` is set only on failed payments.
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
  The refund a `refund.created` event is about.
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
  A validated webhook event.

  `data` is a `Payments.Webhook.Payment` for the payment event types and a
  `Payments.Webhook.Refund` for `:refund_created`.
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
  Turns a decoded webhook payload from the payment provider into a
  `Payments.Webhook.Event`.

  Supported event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type is rejected with `{:unsupported_event, type}`
  so the caller can acknowledge it without acting on it.
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
  Parses a payload with string keys into an event.

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
      iex> {event.type, event.occurred_at, event.data.amount, event.data.currency}
      {:payment_succeeded, ~U[2024-09-22 10:13:20Z], 1250, "EUR"}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "ping", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "ping"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, :invalid_payload}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => _id, "type" => type, "created" => created, "data" => %{} = data} = payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type} <- parse_type(type),
         {:ok, occurred_at} <- parse_created(created),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, occurred_at: occurred_at, data: data}}
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

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)

  defp parse_data(:payment_failed, data) do
    with {:ok, payment} <- parse_payment(data),
         {:ok, reason} <- string_field(data, "failure_reason") do
      {:ok, %{payment | failure_reason: reason}}
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
         {:ok, customer_email} <- string_field(data, "customer_email") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: String.upcase(currency),
        customer_email: customer_email
      }

      {:ok, payment}
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
