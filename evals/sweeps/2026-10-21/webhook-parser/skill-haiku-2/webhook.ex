defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is one of `PaymentSucceeded`, `PaymentFailed`,
  or `RefundCreated`; match on it to pick the handling.
  """

  @enforce_keys [:id, :created_at, :data]
  defstruct [:id, :created_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          created_at: DateTime.t(),
          data:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data of a `payment.succeeded` event. `amount` is in minor units."

  @enforce_keys [:payment_id, :amount, :currency, :customer_email]
  defstruct [:payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "Data of a `payment.failed` event. `amount` is in minor units."

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

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "Data of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads from the payment provider into structs.

  Payloads arrive as maps with string keys, as a JSON decoder returns them.
  The supported event types are `payment.succeeded`, `payment.failed`, and
  `refund.created`. Any other type returns `{:error, {:unsupported_event, type}}`.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @doc """
  Parses a decoded webhook payload into an `t:Payments.Webhook.Event.t/0`.

  Returns `{:error, {:missing_field, key}}` when a required field is absent and
  `{:error, {:invalid_field, key}}` when it has the wrong type. Amounts must be
  non-negative integers in minor units (cents).

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.data.refund_id
      "re_1"

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- fetch_field(payload, "id", &non_empty_string?/1),
         {:ok, type} <- fetch_field(payload, "type", &non_empty_string?/1),
         {:ok, created} <- fetch_field(payload, "created", &is_integer/1),
         {:ok, data} <- fetch_field(payload, "data", &is_map/1),
         {:ok, created_at} <- to_datetime(created),
         {:ok, event_data} <- parse_data(type, data) do
      {:ok, %Event{id: id, created_at: created_at, data: event_data}}
    end
  end

  def parse(other), do: {:error, {:invalid_payload, other}}

  # Selects by type only. Each parser validates its own fields, so a known
  # type with a missing field reports that field instead of "unsupported".
  defp parse_data("payment.succeeded", data), do: parse_payment_succeeded(data)
  defp parse_data("payment.failed", data), do: parse_payment_failed(data)
  defp parse_data("refund.created", data), do: parse_refund_created(data)
  defp parse_data(type, _data), do: {:error, {:unsupported_event, type}}

  defp parse_payment_succeeded(data) do
    with {:ok, fields} <- parse_payment_fields(data) do
      {:ok, struct!(PaymentSucceeded, fields)}
    end
  end

  defp parse_payment_failed(data) do
    with {:ok, fields} <- parse_payment_fields(data),
         {:ok, failure_reason} <- fetch_optional_string(data, "failure_reason") do
      {:ok, struct!(PaymentFailed, Map.put(fields, :failure_reason, failure_reason))}
    end
  end

  defp parse_refund_created(data) do
    with {:ok, refund_id} <- fetch_field(data, "refund_id", &non_empty_string?/1),
         {:ok, payment_id} <- fetch_field(data, "payment_id", &non_empty_string?/1) do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_payment_fields(data) do
    with {:ok, payment_id} <- fetch_field(data, "payment_id", &non_empty_string?/1),
         {:ok, amount} <- fetch_field(data, "amount", &non_negative_integer?/1),
         {:ok, currency} <- fetch_field(data, "currency", &non_empty_string?/1),
         {:ok, customer_email} <- fetch_field(data, "customer_email", &non_empty_string?/1) do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp to_datetime(unix_seconds) do
    case DateTime.from_unix(unix_seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp fetch_field(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        if valid?.(value) do
          {:ok, value}
        else
          {:error, {:invalid_field, key}}
        end

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  # Optional fields may be absent or nil; anything else must be a string.
  defp fetch_optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
