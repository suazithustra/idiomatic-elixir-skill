defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `data` is a `Payments.Webhook.Payment` for the
  payment events and a `Payments.Webhook.Refund` for `:refund_created`.
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
  Payment fields from a `payment.succeeded` or `payment.failed` event.
  `amount` is in integer minor units (cents).
  """

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Refund fields from a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment-provider webhook payload into structs.

  Payloads are maps with string keys, as the JSON decoder produces them.
  Only the event types the app handles are accepted.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a webhook payload into a `Payments.Webhook.Event`.

  Returns `{:error, :invalid_payload}` when a top-level key is missing,
  `{:error, {:unsupported_event, type}}` for an event type the app does not
  handle, and `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` for a bad field in `data`.

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
      iex> event.data.payment_id
      "pay_9"

  """
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, kind} <- parse_type(type),
         {:ok, created_at} <- parse_created_at(created),
         {:ok, event_data} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: event_data}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  # The type comes from an external system. Each known string gets its own
  # clause; String.to_atom/1 would let a sender grow the atom table forever.
  defp parse_type("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp parse_type("payment.failed"), do: {:ok, :payment_failed}
  defp parse_type("refund.created"), do: {:ok, :refund_created}
  defp parse_type(other), do: {:error, {:unsupported_event, other}}

  defp parse_created_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, created_at} -> {:ok, created_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_created_at(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(kind, data) when kind in [:payment_succeeded, :payment_failed] do
    parse_payment(data)
  end

  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: data["customer_email"],
        failure_reason: data["failure_reason"]
      }

      {:ok, payment}
    end
  end

  defp parse_refund(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %Refund{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end
end
