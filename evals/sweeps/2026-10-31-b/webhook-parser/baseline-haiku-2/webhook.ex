defmodule Payments.Webhook do
  @moduledoc """
  Turns decoded webhook payloads (maps with string keys) from the payment
  provider into structs.

  Understood event types are `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type returns `{:error, {:unsupported_type, type}}`
  so the caller can acknowledge and skip it.
  """

  defmodule Event do
    @moduledoc "A parsed webhook event. `data` is a `Payment` or a `Refund`."
    @enforce_keys [:id, :type, :occurred_at, :data]
    defstruct [:id, :type, :occurred_at, :data]
  end

  defmodule Payment do
    @moduledoc "Payment details from a `payment.*` event. `amount` is in minor units (e.g. cents)."
    @enforce_keys [:payment_id, :amount, :currency]
    defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]
  end

  defmodule Refund do
    @moduledoc "Refund details from a `refund.created` event."
    @enforce_keys [:refund_id, :payment_id]
    defstruct [:refund_id, :payment_id]
  end

  @types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @doc "Parses a decoded webhook payload into an `Event`."
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_binary(type) and is_map(data) do
    with {:ok, kind} <- fetch_type(type),
         {:ok, occurred_at} <- to_datetime(created),
         {:ok, body} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, occurred_at: occurred_at, data: body}}
    end
  end

  def parse(_payload), do: {:error, :malformed_payload}

  @doc "Returns the event type strings this module understands."
  def supported_types, do: Map.keys(@types)

  defp fetch_type(type) do
    case Map.fetch(@types, type) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, {:unsupported_type, type}}
    end
  end

  defp to_datetime(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp to_datetime(_), do: {:error, :invalid_timestamp}

  defp parse_data(kind, data) when kind in [:payment_succeeded, :payment_failed],
    do: parse_payment(data)

  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(%{"payment_id" => payment_id, "amount" => amount, "currency" => currency} = data)
       when is_binary(payment_id) and is_integer(amount) and amount >= 0 and
              is_binary(currency) and byte_size(currency) == 3 do
    {:ok,
     %Payment{
       payment_id: payment_id,
       amount: amount,
       currency: String.upcase(currency),
       customer_email: Map.get(data, "customer_email"),
       failure_reason: Map.get(data, "failure_reason")
     }}
  end

  defp parse_payment(_data), do: {:error, :invalid_payment}

  defp parse_refund(%{"refund_id" => refund_id, "payment_id" => payment_id})
       when is_binary(refund_id) and is_binary(payment_id) do
    {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
  end

  defp parse_refund(_data), do: {:error, :invalid_refund}
end
