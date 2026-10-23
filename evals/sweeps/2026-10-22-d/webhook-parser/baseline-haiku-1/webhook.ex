defmodule Payments.Webhook.Event do
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

defmodule Payments.Webhook.Payment do
  @moduledoc "Data carried by `payment.succeeded` and `payment.failed` events. Amounts are in minor units."

  @enforce_keys [:payment_id, :amount, :currency]
  defstruct [:payment_id, :amount, :currency, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount: non_neg_integer(),
          currency: String.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, {:invalid_data, :payment}}
  def from_map(%{"payment_id" => payment_id, "amount" => amount, "currency" => currency} = data)
      when is_binary(payment_id) and is_integer(amount) and amount >= 0 and is_binary(currency) do
    {:ok,
     %__MODULE__{
       payment_id: payment_id,
       amount: amount,
       currency: currency,
       customer_email: data["customer_email"],
       failure_reason: data["failure_reason"]
     }}
  end

  def from_map(_data), do: {:error, {:invalid_data, :payment}}
end

defmodule Payments.Webhook.Refund do
  @moduledoc "Data carried by `refund.created` events."

  @enforce_keys [:refund_id, :payment_id]
  defstruct [:refund_id, :payment_id]

  @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}

  @doc false
  @spec from_map(map()) :: {:ok, t()} | {:error, {:invalid_data, :refund}}
  def from_map(%{"refund_id" => refund_id, "payment_id" => payment_id})
      when is_binary(refund_id) and is_binary(payment_id) do
    {:ok, %__MODULE__{refund_id: refund_id, payment_id: payment_id}}
  end

  def from_map(_data), do: {:error, {:invalid_data, :refund}}
end

defmodule Payments.Webhook do
  @moduledoc """
  Parses decoded webhook payloads from the payment provider into structs.

  Supported events are `payment.succeeded`, `payment.failed` and
  `refund.created`. Any other type returns `{:error, {:unsupported_type, type}}`
  so the caller can acknowledge and ignore it.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:unsupported_type, String.t()}
          | {:invalid_data, atom()}

  @doc """
  Parses a decoded webhook payload (string keys) into an `Event`.

  ## Examples

      iex> {:ok, event} = Payments.Webhook.parse(payload)
      iex> event.type
      :payment_succeeded
  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_binary(id) and is_integer(created) and is_map(data) do
    with {:ok, kind} <- kind(type),
         {:ok, created_at} <- datetime(created),
         {:ok, payload} <- parse_data(kind, data) do
      {:ok, %Event{id: id, type: kind, created_at: created_at, data: payload}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp kind("payment.succeeded"), do: {:ok, :payment_succeeded}
  defp kind("payment.failed"), do: {:ok, :payment_failed}
  defp kind("refund.created"), do: {:ok, :refund_created}
  defp kind(type), do: {:error, {:unsupported_type, type}}

  defp datetime(created) do
    case DateTime.from_unix(created) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_data, :created}}
    end
  end

  defp parse_data(:payment_succeeded, data), do: Payment.from_map(data)
  defp parse_data(:payment_failed, data), do: Payment.from_map(data)
  defp parse_data(:refund_created, data), do: Refund.from_map(data)
end
