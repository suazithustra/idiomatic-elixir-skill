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

defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment from a `payment.succeeded` or `payment.failed` event.
  `failure_reason` is `nil` unless the payment failed.
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
  A refund from a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider.

  Handles `payment.succeeded`, `payment.failed`, and `refund.created`.
  Amounts are integer minor units (for example, cents).
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @doc """
  Parses a decoded webhook payload into a `Payments.Webhook.Event`.

  Returns `{:error, {:unsupported_event, type}}` for event types this app
  does not handle. Returns `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when a field is absent or has the wrong shape.

  ## Examples

      iex> {:ok, event} =
      ...>   Payments.Webhook.parse(%{
      ...>     "id" => "evt_1",
      ...>     "type" => "refund.created",
      ...>     "created" => 1727000000,
      ...>     "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...>   })
      iex> {event.type, event.data.refund_id}
      {:refund_created, "re_1"}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) do
    with {:ok, type} <- event_type(payload),
         {:ok, id} <- string_field(payload, "id"),
         {:ok, created_at} <- created_at(payload),
         {:ok, data} <- map_field(payload, "data"),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  defp event_type(payload) do
    case string_field(payload, "type") do
      {:ok, "payment.succeeded"} -> {:ok, :payment_succeeded}
      {:ok, "payment.failed"} -> {:ok, :payment_failed}
      {:ok, "refund.created"} -> {:ok, :refund_created}
      {:ok, other} -> {:error, {:unsupported_event, other}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
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

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp created_at(payload) do
    case integer_field(payload, "created") do
      {:ok, seconds} -> datetime_from_unix(seconds)
      {:error, _reason} = error -> error
    end
  end

  defp datetime_from_unix(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp amount_field(data) do
    case integer_field(data, "amount") do
      {:ok, amount} when amount >= 0 -> {:ok, amount}
      {:ok, _negative} -> {:error, {:invalid_field, "amount"}}
      {:error, _reason} = error -> error
    end
  end

  defp string_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      :error -> {:error, {:missing_field, key}}
      {:ok, _other} -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string_field(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp integer_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      :error -> {:error, {:missing_field, key}}
      {:ok, _other} -> {:error, {:invalid_field, key}}
    end
  end

  defp map_field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, key}}
      :error -> {:error, {:missing_field, key}}
      {:ok, _other} -> {:error, {:invalid_field, key}}
    end
  end
end
