defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into
  `Payments.Webhook.Event` structs.

  The input is a map with string keys, as a JSON decoder returns it. Amounts are
  integer minor units (cents). `created` is a Unix timestamp in seconds.

  Supported event types and the `data` fields each one requires:

    * `"payment.succeeded"` - `payment_id`, `amount`, `currency`, `customer_email`
    * `"payment.failed"` - `payment_id`, `amount`, `currency`; `failure_reason` is
      optional and may be `nil`
    * `"refund.created"` - `refund_id`, `payment_id`
  """

  alias Payments.Webhook.Event

  @doc """
  Parses a webhook payload into a `Payments.Webhook.Event`.

  Returns `{:ok, event}` or `{:error, reason}`, where `reason` is one of:

    * `:invalid_payload` - `id`, `type`, `created` or `data` is missing
    * `{:unsupported_event, type}` - the event type is not one this module handles
    * `{:missing_field, key}` - a required field inside `data` is absent
    * `{:invalid_field, key}` - a field is present with the wrong type or value

  ## Examples

      iex> Payments.Webhook.parse(%{"nope" => true})
      {:error, :invalid_payload}

  """
  def parse(%{"id" => _, "type" => _, "created" => _, "data" => _} = payload) do
    with {:ok, id} <- string_field(payload, "id"),
         {:ok, kind} <- event_kind(payload["type"]),
         {:ok, occurred_at} <- parse_created(payload["created"]),
         {:ok, data} <- data_map(payload["data"]),
         {:ok, fields} <- event_fields(kind, data) do
      attrs = [id: id, type: kind, occurred_at: occurred_at] ++ fields
      {:ok, struct!(Event, attrs)}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(type), do: {:error, {:unsupported_event, type}}

  defp event_fields(:payment_succeeded, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      fields = [
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      ]

      {:ok, fields}
    end
  end

  defp event_fields(:payment_failed, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, failure_reason} <- failure_reason(data) do
      fields = [
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        failure_reason: failure_reason
      ]

      {:ok, fields}
    end
  end

  defp event_fields(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, [refund_id: refund_id, payment_id: payment_id]}
    end
  end

  defp parse_created(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created(_created), do: {:error, {:invalid_field, "created"}}

  defp data_map(data) when is_map(data), do: {:ok, data}
  defp data_map(_data), do: {:error, {:invalid_field, "data"}}

  defp string_field(map, key) do
    case map do
      %{^key => value} when is_binary(value) ->
        {:ok, value}

      %{^key => _value} ->
        {:error, {:invalid_field, key}}

      %{} ->
        {:error, {:missing_field, key}}
    end
  end

  defp amount_field(data, key) do
    case data do
      %{^key => value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      %{^key => _value} ->
        {:error, {:invalid_field, key}}

      %{} ->
        {:error, {:missing_field, key}}
    end
  end

  defp failure_reason(data) do
    case data do
      %{"failure_reason" => reason} when is_binary(reason) or is_nil(reason) ->
        {:ok, reason}

      %{"failure_reason" => _reason} ->
        {:error, {:invalid_field, "failure_reason"}}

      %{} ->
        {:ok, nil}
    end
  end
end

defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. Fields that the event's `:type` does not carry are `nil`.
  """

  @enforce_keys [:id, :type, :occurred_at]
  defstruct [
    :id,
    :type,
    :occurred_at,
    :payment_id,
    :refund_id,
    :amount,
    :currency,
    :customer_email,
    :failure_reason
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          payment_id: String.t() | nil,
          refund_id: String.t() | nil,
          amount: non_neg_integer() | nil,
          currency: String.t() | nil,
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end
