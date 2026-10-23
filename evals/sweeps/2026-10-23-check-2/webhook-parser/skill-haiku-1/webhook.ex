defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into an `Event`.

  The payload is a map with string keys, as a JSON decoder returns it.
  Amounts are integers in minor units (cents). Handled event types are
  `payment.succeeded`, `payment.failed` and `refund.created`.
  """

  defmodule Payment do
    @moduledoc "Payment data carried by `payment.succeeded` and `payment.failed` events."

    @enforce_keys [:id, :amount, :currency, :customer_email]
    defstruct [:id, :amount, :currency, :customer_email, :failure_reason]

    @type t :: %__MODULE__{
            id: String.t(),
            amount: integer(),
            currency: String.t(),
            customer_email: String.t(),
            failure_reason: String.t() | nil
          }
  end

  defmodule Refund do
    @moduledoc "Refund data carried by `refund.created` events."

    @enforce_keys [:id, :payment_id]
    defstruct [:id, :payment_id]

    @type t :: %__MODULE__{id: String.t(), payment_id: String.t()}
  end

  defmodule Event do
    @moduledoc "A parsed webhook event."

    @enforce_keys [:id, :type, :created_at, :data]
    defstruct [:id, :type, :created_at, :data]

    @type t :: %__MODULE__{
            id: String.t(),
            type: :payment_succeeded | :payment_failed | :refund_created,
            created_at: DateTime.t(),
            data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
          }
  end

  @doc """
  Parses a webhook payload into an `Event`.

  Errors:

    * `{:error, :invalid_payload}` - the `id`, `type`, `created` or `data` key is missing or has the wrong type
    * `{:error, {:unsupported_event, type}}` - the event type is not one this module handles
    * `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}` - a field inside `data` is wrong

  ## Examples

      iex> Payments.Webhook.parse(%{"id" => "evt_1", "type" => "dispute.opened", "created" => 0, "data" => %{}})
      {:error, {:unsupported_event, "dispute.opened"}}
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_integer(created) and is_map(data) do
    parse_event(type, id, created, data)
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # The event type selects the parser here; the fields of `data` are checked in
  # the parsers below. A known type with a bad field therefore reports the field,
  # not "unsupported event".
  defp parse_event("payment.succeeded", id, created, data) do
    event(id, created, :payment_succeeded, payment(data))
  end

  defp parse_event("payment.failed", id, created, data) do
    event(id, created, :payment_failed, payment(data))
  end

  defp parse_event("refund.created", id, created, data) do
    event(id, created, :refund_created, refund(data))
  end

  defp parse_event(type, _id, _created, _data), do: {:error, {:unsupported_event, type}}

  defp event(id, created, type, parsed_data) do
    with {:ok, data} <- parsed_data,
         {:ok, created_at} <- created_at(created) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  defp payment(data) do
    with {:ok, id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      # Optional: absent or nil means the payment has no failure reason.
      payment = %Payment{
        id: id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: data["failure_reason"]
      }

      {:ok, payment}
    end
  end

  defp refund(data) do
    with {:ok, id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{id: id, payment_id: payment_id}}
    end
  end

  defp created_at(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp string_field(data, key), do: typed_field(data, key, &is_binary/1)

  defp integer_field(data, key), do: typed_field(data, key, &is_integer/1)

  defp typed_field(data, key, predicate) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        if predicate.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
