defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is one of the structs in this namespace,
  picked by `type`.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          data:
            Payments.Webhook.PaymentSucceeded.t()
            | Payments.Webhook.PaymentFailed.t()
            | Payments.Webhook.RefundCreated.t()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "Data of a `payment.succeeded` event."

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
  @moduledoc "Data of a `payment.failed` event."

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
  Turns a webhook payload from the payment provider into a
  `Payments.Webhook.Event`.

  The payload is the map produced by JSON decoding, with string keys.
  Amounts are integers in minor units (for example cents).
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @doc """
  Parses a webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` for `payment.succeeded`,
  `payment.failed` and `refund.created`. Otherwise returns `{:error, reason}`:

    * `{:unsupported_event, type}` for any other event type
    * `{:missing_field, key}` or `{:invalid_field, key}` for a bad field in `data`
    * `{:invalid_field, "created"}` when `created` is not a valid Unix time
    * `:invalid_payload` when `id`, `type`, `created` or `data` is absent
  """
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) do
    with {:ok, kind} <- event_kind(type),
         {:ok, occurred_at} <- occurred_at(created),
         {:ok, fields} <- data_map(data),
         {:ok, payload} <- payload(kind, fields) do
      {:ok, %Event{id: id, type: kind, occurred_at: occurred_at, data: payload}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp occurred_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} ->
        {:ok, occurred_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp data_map(data) when is_map(data), do: {:ok, data}
  defp data_map(_data), do: {:error, {:invalid_field, "data"}}

  defp payload(:payment_succeeded, fields) do
    with {:ok, payment} <- payment_fields(fields) do
      {:ok, struct!(PaymentSucceeded, payment)}
    end
  end

  defp payload(:payment_failed, fields) do
    with {:ok, payment} <- payment_fields(fields) do
      failure_reason = Map.get(fields, "failure_reason")
      {:ok, struct!(PaymentFailed, Map.put(payment, :failure_reason, failure_reason))}
    end
  end

  defp payload(:refund_created, fields) do
    with {:ok, refund_id} <- string_field(fields, "refund_id"),
         {:ok, payment_id} <- string_field(fields, "payment_id") do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp payment_fields(fields) do
    with {:ok, payment_id} <- string_field(fields, "payment_id"),
         {:ok, amount} <- amount_field(fields),
         {:ok, currency} <- string_field(fields, "currency"),
         {:ok, customer_email} <- string_field(fields, "customer_email") do
      payment = %{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, payment}
    end
  end

  defp string_field(fields, key), do: field(fields, key, &is_binary/1)

  defp amount_field(fields) do
    field(fields, "amount", fn amount -> is_integer(amount) and amount >= 0 end)
  end

  defp field(fields, key, valid?) do
    case Map.fetch(fields, key) do
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
end
