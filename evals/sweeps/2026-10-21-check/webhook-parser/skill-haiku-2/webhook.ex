defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event."

  alias Payments.Webhook.{PaymentFailed, PaymentSucceeded, RefundCreated}

  @enforce_keys [:id, :type, :created_at, :data]
  defstruct [:id, :type, :created_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          created_at: DateTime.t(),
          data: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data of a `payment.succeeded` event."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data of a `payment.failed` event."

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

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into structs.

  Payloads use string keys, as a JSON decoder produces them. Amounts are
  integer minor units (cents).
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @doc """
  Parses a decoded webhook payload into an `Event`.

  Returns `{:error, {:unsupported_event, type}}` for event types this app
  does not handle, and `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` for a payload with a bad field.

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
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, type} <- fetch_string(payload, "type"),
         {:ok, kind} <- event_kind(type),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created} <- fetch_integer(payload, "created"),
         {:ok, created_at} <- unix_time(created),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, body} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(type), do: {:error, {:unsupported_event, type}}

  defp parse_data(:payment_succeeded, data) do
    with {:ok, fields} <- payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, fields)}
    end
  end

  defp parse_data(:payment_failed, data) do
    with {:ok, fields} <- payment_fields(data),
         {:ok, failure_reason} <- optional_string(data, "failure_reason") do
      {:ok, struct!(PaymentFailed, Map.put(fields, :failure_reason, failure_reason))}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id") do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp payment_fields(data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_integer(data, "amount"),
         {:ok, currency} <- fetch_string(data, "currency"),
         {:ok, customer_email} <- optional_string(data, "customer_email") do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: String.upcase(currency),
         customer_email: customer_email
       }}
    end
  end

  defp unix_time(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:missing_field, key}}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      nil -> {:error, {:missing_field, key}}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      nil -> {:error, {:missing_field, key}}
      _other -> {:error, {:invalid_field, key}}
    end
  end
end
