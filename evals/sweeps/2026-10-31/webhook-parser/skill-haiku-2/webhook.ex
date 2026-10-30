defmodule Payments.Webhook.Event do
  @moduledoc """
  A parsed webhook event. `object` is one of the structs for its `type`.
  """

  @enforce_keys [:id, :type, :occurred_at, :object]
  defstruct [:id, :type, :occurred_at, :object]

  @type t :: %__MODULE__{
          id: String.t(),
          type: :payment_succeeded | :payment_failed | :refund_created,
          occurred_at: DateTime.t(),
          object: struct()
        }
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc false

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
  @moduledoc false

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
  @moduledoc false

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment provider webhook payload into structs.

  The payload is a map with string keys, as a JSON decoder returns it.
  Amounts are integer minor units (cents).
  """

  alias Payments.Webhook.Event
  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @doc """
  Parses a webhook payload into an `Payments.Webhook.Event`.

  Returns `{:error, {:unsupported_event, type}}` for event types this app does
  not handle, `{:error, {:missing_field, key}}` when a required field is absent,
  and `{:error, {:invalid_field, key}}` when a field has the wrong type.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.object.refund_id
      "re_1"

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
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

  defp occurred_at(created) when is_integer(created), do: DateTime.from_unix(created)
  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp object(:payment_succeeded, data), do: payment_succeeded(data)
  defp object(:payment_failed, data), do: payment_failed(data)
  defp object(:refund_created, data), do: refund_created(data)

  defp payment_succeeded(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %PaymentSucceeded{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: Map.get(data, "customer_email")
      }

      {:ok, payment}
    end
  end

  defp payment_failed(data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- amount_field(data),
         {:ok, currency} <- string_field(data, "currency") do
      payment = %PaymentFailed{
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: Map.get(data, "customer_email"),
        failure_reason: Map.get(data, "failure_reason")
      }

      {:ok, payment}
    end
  end

  defp refund_created(data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp string_field(data, key), do: field(data, key, &is_binary/1)

  defp amount_field(data), do: field(data, "amount", &(is_integer(&1) and &1 >= 0))

  defp field(data, key, valid?) do
    case Map.fetch(data, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
