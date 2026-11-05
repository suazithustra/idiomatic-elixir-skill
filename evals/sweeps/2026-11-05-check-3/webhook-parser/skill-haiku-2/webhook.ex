defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event: its id, its kind, the time it was created, and its data.
  """

  @enforce_keys [:id, :type, :occurred_at, :data]
  defstruct [:id, :type, :occurred_at, :data]

  @type kind :: :payment_succeeded | :payment_failed | :refund_created

  @type t :: %__MODULE__{
          id: String.t(),
          type: kind(),
          occurred_at: DateTime.t(),
          data: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  Data of a `payment.succeeded` or `payment.failed` event.

  `amount` is in integer minor units (for example cents). `customer_email` and
  `failure_reason` are `nil` when the payload does not include them.
  """

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: term() | nil
        }
end

defmodule Payments.Webhook.Refund do
  @moduledoc """
  Data of a `refund.created` event.
  """

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a webhook payload from the payment provider into a `Payments.Webhook.Event`.

  The payload is a map with string keys, as produced by a JSON decoder. Three event
  types are handled: `payment.succeeded`, `payment.failed` and `refund.created`.
  Any other type returns `{:error, {:unsupported_event, type}}`, so the caller
  decides what to do with it.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @type error ::
          :invalid_payload
          | {:unsupported_event, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @doc """
  Parses a decoded webhook payload.

  Returns `{:ok, event}` or `{:error, reason}`. A payload without `"id"`,
  `"type"`, `"created"` or `"data"` returns `{:error, :invalid_payload}`.

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
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, kind} <- event_kind(type),
         {:ok, occurred_at} <- parse_time(created),
         {:ok, object} <- parse_data(kind, data) do
      event = %Event{id: id, type: kind, occurred_at: occurred_at, data: object}
      {:ok, event}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(other), do: {:error, {:unsupported_event, other}}

  defp parse_time(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} ->
        {:ok, occurred_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_time(_created), do: {:error, {:invalid_field, "created"}}

  defp parse_data(:payment_succeeded, data), do: parse_payment(data)
  defp parse_data(:payment_failed, data), do: parse_payment(data)
  defp parse_data(:refund_created, data), do: parse_refund(data)

  defp parse_payment(data) do
    with {:ok, payment_id} <- required(data, "payment_id", &non_empty_string?/1),
         {:ok, amount} <- required(data, "amount", &minor_units?/1),
         {:ok, currency} <- required(data, "currency", &non_empty_string?/1) do
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
    with {:ok, refund_id} <- required(data, "refund_id", &non_empty_string?/1),
         {:ok, payment_id} <- required(data, "payment_id", &non_empty_string?/1) do
      refund = %Refund{refund_id: refund_id, payment_id: payment_id}
      {:ok, refund}
    end
  end

  defp required(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp minor_units?(value), do: is_integer(value) and value >= 0
end
