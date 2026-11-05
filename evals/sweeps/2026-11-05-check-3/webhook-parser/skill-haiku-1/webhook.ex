defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `object` is a `Payments.Webhook.Payment` for the
  payment event types and a `Payments.Webhook.Refund` for `:refund_created`.
  """

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          object: Payments.Webhook.Payment.t() | Payments.Webhook.Refund.t()
        }
end

defmodule Payments.Webhook.Payment do
  @moduledoc """
  A payment carried by a `payment.succeeded` or `payment.failed` event.
  `amount` is in integer minor units. `failure_reason` is set only for
  failed payments.
  """

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

defmodule Payments.Webhook.Refund do
  @moduledoc """
  A refund carried by a `refund.created` event. `amount` is in integer
  minor units.
  """

  @enforce_keys [:refund_id, :payment_id, :amount, :currency]
  defstruct [:refund_id, :payment_id, :amount, :currency]

  @type t :: %__MODULE__{
          refund_id: String.t(),
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into a
  `Payments.Webhook.Event`.

  The payload is a map with string keys, as produced by a JSON decoder.
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.Payment
  alias Payments.Webhook.Refund

  @doc """
  Parses a decoded webhook payload.

  Returns `{:ok, %Payments.Webhook.Event{}}` for `payment.succeeded`,
  `payment.failed` and `refund.created`.

  Errors:

    * `{:error, :invalid_payload}` - a top-level key is missing or has the wrong type
    * `{:error, {:unsupported_event, type}}` - the event type is not one we handle
    * `{:error, {:missing_field, key}}` - a field in `data` is absent
    * `{:error, {:invalid_field, key}}` - a field in `data` has the wrong type

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{
      ...>     "refund_id" => "re_1",
      ...>     "payment_id" => "pay_9",
      ...>     "amount" => 500,
      ...>     "currency" => "eur"
      ...>   }
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> {event.type, event.object.amount}
      {:refund_created, 500}

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_map(data) do
    with {:ok, kind} <- event_kind(type),
         {:ok, occurred_at} <- occurred_at(created),
         {:ok, object} <- object(kind, data) do
      {:ok, %Event{id: id, type: kind, occurred_at: occurred_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(type), do: {:error, {:unsupported_event, type}}

  defp occurred_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} -> {:ok, occurred_at}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp object(:payment_succeeded, data), do: payment(data)

  defp object(:payment_failed, data) do
    with {:ok, payment} <- payment(data),
         {:ok, failure_reason} <- string_field(data, "failure_reason") do
      {:ok, %Payment{payment | failure_reason: failure_reason}}
    end
  end

  defp object(:refund_created, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency") do
      refund = %Refund{
        refund_id: refund_id,
        payment_id: payment_id,
        amount: amount,
        currency: currency
      }

      {:ok, refund}
    end
  end

  defp payment(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- optional_string_field(data, "customer_email") do
      payment = %Payment{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, payment}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp optional_string_field(data, key) do
    case Map.get(data, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp amount_field(data) do
    case Map.fetch(data, "amount") do
      {:ok, amount} when is_integer(amount) and amount >= 0 -> {:ok, amount}
      {:ok, _amount} -> {:error, {:invalid_field, "amount"}}
      :error -> {:error, {:missing_field, "amount"}}
    end
  end
end
