defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A `payment.succeeded` event from the payment provider."

  @enforce_keys [:id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [:id, :occurred_at, :payment_id, :amount, :currency, :customer_email]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t()
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A `payment.failed` event from the payment provider."

  @enforce_keys [:id, :occurred_at, :payment_id, :amount, :currency, :customer_email]
  defstruct [:id, :occurred_at, :payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          amount: integer(),
          currency: String.t(),
          customer_email: String.t(),
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A `refund.created` event from the payment provider."

  @enforce_keys [:id, :occurred_at, :refund_id, :payment_id]
  defstruct [:id, :occurred_at, :refund_id, :payment_id]

  @type t :: %__MODULE__{
          id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded payment provider webhook payload into a typed event struct.

  Only `payment.succeeded`, `payment.failed` and `refund.created` are
  supported. Any other event type, or a payload that is missing a required
  field, returns an error tuple.

  Amounts are integers in minor units (for example cents).
  """

  alias Payments.Webhook.PaymentFailed
  alias Payments.Webhook.PaymentSucceeded
  alias Payments.Webhook.RefundCreated

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @doc """
  Parses a decoded webhook payload with string keys.

  ## Examples

      iex> payload = %{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> }
      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.refund_id
      "re_1"

      iex> Payments.Webhook.parse(%{"id" => "evt_2"})
      {:error, :invalid_payload}

  """
  @spec parse(map()) :: {:ok, event()} | {:error, term()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => %{} = data})
      when is_binary(id) do
    with {:ok, occurred_at} <- occurred_at(created),
         {:ok, kind} <- event_kind(type) do
      build(kind, id, occurred_at, data)
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp occurred_at(created) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, occurred_at} ->
        {:ok, occurred_at}

      {:error, _reason} ->
        {:error, {:invalid_field, "created"}}
    end
  end

  defp occurred_at(_created), do: {:error, {:invalid_field, "created"}}

  defp event_kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp event_kind("payment.failed"), do: {:ok, :payment_failed}
  defp event_kind("refund.created"), do: {:ok, :refund_created}
  defp event_kind(type), do: {:error, {:unsupported_event, type}}

  defp build(:payment_succeeded, id, occurred_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      event = %PaymentSucceeded{
        id: id,
        occurred_at: occurred_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email
      }

      {:ok, event}
    end
  end

  defp build(:payment_failed, id, occurred_at, data) do
    with {:ok, payment_id} <- string_field(data, "payment_id"),
         {:ok, amount} <- integer_field(data, "amount"),
         {:ok, currency} <- string_field(data, "currency"),
         {:ok, customer_email} <- string_field(data, "customer_email") do
      event = %PaymentFailed{
        id: id,
        occurred_at: occurred_at,
        payment_id: payment_id,
        amount: amount,
        currency: currency,
        customer_email: customer_email,
        failure_reason: data["failure_reason"]
      }

      {:ok, event}
    end
  end

  defp build(:refund_created, id, occurred_at, data) do
    with {:ok, refund_id} <- string_field(data, "refund_id"),
         {:ok, payment_id} <- string_field(data, "payment_id") do
      event = %RefundCreated{
        id: id,
        occurred_at: occurred_at,
        refund_id: refund_id,
        payment_id: payment_id
      }

      {:ok, event}
    end
  end

  defp string_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp integer_field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} when is_integer(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end
end
