defmodule Payments.Webhook.Payment do
  @moduledoc """
  Payment details carried by `payment.succeeded` and `payment.failed` events.

  `amount` is in minor units (for example cents). `failure_reason` is `nil`
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

  `amount` is in minor units (for example cents).
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
  Turns a decoded webhook payload from the payment provider into an
  `Payments.Webhook.Event`.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | {:unsupported_event, String.t()}

  @doc """
  Parses a string-keyed payload into an event.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  naming the first field that fails validation, and
  `{:error, {:unsupported_event, type}}` for event types we do not handle.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
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

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "customer.created"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1"})
      {:error, {:missing_field, "type"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{} = payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, type} <- string_field(payload, "type"),
         {:ok, created_at} <- timestamp_field(payload, "created"),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, type} <- parse_type(type),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency") do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email"),
         {:ok, failure_reason} <- failure_reason(type, data) do
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

  defp failure_reason(:payment_failed, data), do: string_field(data, "failure_reason")
  defp failure_reason(:payment_succeeded, _data), do: {:ok, nil}

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, %{} = value} -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp amount_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp timestamp_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, seconds} when is_integer(seconds) -> from_unix(seconds, key)
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp from_unix(seconds, key) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, key}}
    end
  end
end
