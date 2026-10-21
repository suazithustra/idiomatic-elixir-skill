defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload from the payment provider into structs.

  Handled event types:

    * `payment.succeeded`
    * `payment.failed`
    * `refund.created`

  Any other type returns `{:error, {:unsupported_event, type}}` so the caller
  can acknowledge and ignore it.

  Amounts are integer minor units (for example cents). Floats, negative values
  and missing required fields are rejected.
  """

  @supported_types ~w(payment.succeeded payment.failed refund.created)

  defmodule Event do
    @moduledoc "A parsed webhook event. `object` holds the event-specific struct."

    @enforce_keys [:id, :type, :created_at, :object]
    defstruct [:id, :type, :created_at, :object]

    @type t :: %__MODULE__{
            id: String.t(),
            type: String.t(),
            created_at: DateTime.t(),
            object:
              Payments.Webhook.PaymentSucceeded.t()
              | Payments.Webhook.PaymentFailed.t()
              | Payments.Webhook.RefundCreated.t()
          }
  end

  defmodule PaymentSucceeded do
    @moduledoc "Data for a `payment.succeeded` event."

    @enforce_keys [:payment_id, :amount, :currency]
    defstruct [:payment_id, :amount, :currency, :customer_email]

    @type t :: %__MODULE__{
            payment_id: String.t(),
            amount: non_neg_integer(),
            currency: String.t(),
            customer_email: String.t() | nil
          }
  end

  defmodule PaymentFailed do
    @moduledoc "Data for a `payment.failed` event."

    @enforce_keys [:payment_id, :amount, :currency]
    defstruct [:payment_id, :amount, :currency, :failure_reason]

    @type t :: %__MODULE__{
            payment_id: String.t(),
            amount: non_neg_integer(),
            currency: String.t(),
            failure_reason: String.t() | nil
          }
  end

  defmodule RefundCreated do
    @moduledoc "Data for a `refund.created` event."

    @enforce_keys [:refund_id, :payment_id]
    defstruct [:refund_id, :payment_id]

    @type t :: %__MODULE__{refund_id: String.t(), payment_id: String.t()}
  end

  @doc """
  Parses a decoded webhook payload.

  ## Examples

      iex> {:ok, event} = Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1727000000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}
      ...> })
      iex> event.object.refund_id
      "re_1"

  """
  @spec parse(map()) :: {:ok, Event.t()} | {:error, term()}
  def parse(payload) when is_map(payload) do
    with {:ok, id} <- required_string(payload, "id"),
         {:ok, type} <- required_string(payload, "type"),
         {:ok, created} <- required_integer(payload, "created"),
         {:ok, data} <- required_map(payload, "data"),
         {:ok, created_at} <- to_datetime(created),
         {:ok, object} <- parse_object(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, object: object}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  @doc "Returns true when the event type is one this module handles."
  @spec supported_type?(term()) :: boolean()
  def supported_type?(type), do: type in @supported_types

  defp parse_object("payment.succeeded", data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- required_amount(data, "amount"),
         {:ok, currency} <- required_currency(data),
         {:ok, email} <- optional_string(data, "customer_email") do
      {:ok,
       %PaymentSucceeded{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email
       }}
    end
  end

  defp parse_object("payment.failed", data) do
    with {:ok, payment_id} <- required_string(data, "payment_id"),
         {:ok, amount} <- required_amount(data, "amount"),
         {:ok, currency} <- required_currency(data),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %PaymentFailed{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         failure_reason: reason
       }}
    end
  end

  defp parse_object("refund.created", data) do
    with {:ok, refund_id} <- required_string(data, "refund_id"),
         {:ok, payment_id} <- required_string(data, "payment_id") do
      {:ok, %RefundCreated{refund_id: refund_id, payment_id: payment_id}}
    end
  end

  defp parse_object(type, _data), do: {:error, {:unsupported_event, type}}

  defp to_datetime(unix) do
    case DateTime.from_unix(unix) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp required_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp required_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp required_map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp required_amount(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  # ISO 4217 codes are three letters. Stored upper-cased, so "eur" becomes "EUR".
  defp required_currency(map) do
    with {:ok, code} <- required_string(map, "currency") do
      if code =~ ~r/\A[A-Za-z]{3}\z/ do
        {:ok, String.upcase(code)}
      else
        {:error, {:invalid_field, "currency"}}
      end
    end
  end
end
