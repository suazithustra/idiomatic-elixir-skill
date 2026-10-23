defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `object` is one of the payload structs in `Payments.Webhook`.
  """

  @enforce_keys [:id, :occurred_at, :object]
  defstruct [:id, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          object:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "The `data` of a `payment.succeeded` event. `amount` is in minor units."

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
  @moduledoc "The `data` of a `payment.failed` event. `amount` is in minor units."

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
  @moduledoc "The `data` of a `refund.created` event."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Event types this app does not handle return an error instead of raising, so
  the endpoint can acknowledge them and move on.
  """

  alias Payments.Webhook.{Event, PaymentFailed, PaymentSucceeded, RefundCreated}

  @doc """
  Parses a payload whose keys are strings, as decoded from JSON.

  Returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`
  for the first bad top-level field, and `{:error, {:unsupported_event, type}}`
  for an event type this app does not handle.

  ## Examples

      iex> Payments.Webhook.parse(%{})
      {:error, {:missing_field, "id"}}

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "customer.created", "created" => 1727000000, "data" => %{}})
      {:error, {:unsupported_event, "customer.created"}}
  """
  @spec parse(term()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- required_field(payload, "id", &is_binary/1),
         {:ok, type} <- required_field(payload, "type", &is_binary/1),
         {:ok, created} <- required_field(payload, "created", &is_integer/1),
         {:ok, occurred_at} <- occurred_at(created),
         {:ok, data} <- required_field(payload, "data", &is_map/1),
         {:ok, object} <- parse_object(type, data) do
      {:ok, %Event{id: id, occurred_at: occurred_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp occurred_at(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  # Selects the struct from the event type only. Field checks live in the
  # per-type functions, so a known type with a bad field is not reported as
  # an unsupported event.
  defp parse_object("payment.succeeded", data), do: payment_succeeded(data)
  defp parse_object("payment.failed", data), do: payment_failed(data)
  defp parse_object("refund.created", data), do: refund_created(data)
  defp parse_object(type, _data), do: {:error, {:unsupported_event, type}}

  defp payment_succeeded(data) do
    case payment_fields(data) do
      {:ok, fields} -> {:ok, struct!(PaymentSucceeded, fields)}
      {:error, _reason} = error -> error
    end
  end

  defp payment_failed(data) do
    case payment_fields(data) do
      {:ok, fields} ->
        {:ok, struct!(PaymentFailed, Map.put(fields, :failure_reason, data["failure_reason"]))}

      {:error, _reason} = error ->
        error
    end
  end

  defp payment_fields(data) do
    with {:ok, payment_id} <- required_field(data, "payment_id", &is_binary/1),
         {:ok, amount} <- required_field(data, "amount", &non_negative_integer?/1),
         {:ok, currency} <- required_field(data, "currency", &is_binary/1),
         {:ok, customer_email} <- required_field(data, "customer_email", &is_binary/1) do
      {:ok,
       %{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: customer_email
       }}
    end
  end

  defp refund_created(data) do
    with {:ok, refund_id} <- required_field(data, "refund_id", &is_binary/1),
         {:ok, payment_id} <- required_field(data, "payment_id", &is_binary/1) do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp required_field(fields, key, valid?) do
    case Map.fetch(fields, key) do
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp non_negative_integer?(amount), do: is_integer(amount) and amount >= 0
end
