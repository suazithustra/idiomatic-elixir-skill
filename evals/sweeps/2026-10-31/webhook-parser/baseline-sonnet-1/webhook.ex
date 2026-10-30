defmodule Payments.Webhook.Event do
  @moduledoc "A parsed webhook event. `data` is a `Payments.Webhook.Payment` or `Payments.Webhook.Refund`."

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
  @moduledoc "Payment details from `payment.succeeded` and `payment.failed` events."

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
  @moduledoc "Refund details from `refund.created` events."

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
  Parses decoded payment-provider webhook payloads into structs.

      iex> Payments.Webhook.parse(%{
      ...>   "id" => "evt_1",
      ...>   "type" => "refund.created",
      ...>   "created" => 1_727_000_000,
      ...>   "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9", "amount" => 500, "currency" => "eur"}
      ...> })
      {:ok,
       %Payments.Webhook.Event{
         id: "evt_1",
         type: :refund_created,
         created_at: ~U[2024-09-22 09:46:40Z],
         data: %Payments.Webhook.Refund{
           refund_id: "re_1",
           payment_id: "pay_9",
           amount: 500,
           currency: "EUR"
         }
       }}

  Amounts are integers in minor units (for example cents). Currency codes are
  normalised to upper case.
  """

  alias Payments.Webhook.{Event, Payment, Refund}

  @type error ::
          :invalid_payload
          | {:unsupported_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}

  @types %{
    "payment.succeeded" => :payment_succeeded,
    "payment.failed" => :payment_failed,
    "refund.created" => :refund_created
  }

  @spec parse(term()) :: {:ok, Event.t()} | {:error, error()}
  def parse(%{"type" => type} = payload) do
    with {:ok, type} <- parse_type(type),
         {:ok, id} <- fetch_string(payload, "id"),
         {:ok, created_at} <- fetch_timestamp(payload, "created"),
         {:ok, data} <- fetch_map(payload, "data"),
         {:ok, data} <- parse_data(type, data) do
      {:ok, %Event{id: id, type: type, created_at: created_at, data: data}}
    end
  end

  def parse(%{}), do: {:error, {:missing_field, "type"}}
  def parse(_other), do: {:error, :invalid_payload}

  defp parse_type(type) when is_map_key(@types, type), do: {:ok, Map.fetch!(@types, type)}
  defp parse_type(type), do: {:error, {:unsupported_type, type}}

  defp parse_data(type, data) when type in [:payment_succeeded, :payment_failed] do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency"),
         {:ok, email} <- optional_string(data, "customer_email"),
         {:ok, reason} <- optional_string(data, "failure_reason") do
      {:ok,
       %Payment{
         payment_id: payment_id,
         amount: amount,
         currency: currency,
         customer_email: email,
         failure_reason: reason
       }}
    end
  end

  defp parse_data(:refund_created, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, amount} <- fetch_amount(data, "amount"),
         {:ok, currency} <- fetch_currency(data, "currency") do
      {:ok,
       %Refund{refund_id: refund_id, payment_id: payment_id, amount: amount, currency: currency}}
    end
  end

  defp fetch(map, key) do
    case map do
      %{^key => value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_string(map, key) do
    with {:ok, value} <- fetch(map, key), do: validate(is_binary(value) and value != "", value, key)
  end

  defp fetch_map(map, key) do
    with {:ok, value} <- fetch(map, key), do: validate(is_map(value), value, key)
  end

  defp fetch_amount(map, key) do
    with {:ok, value} <- fetch(map, key), do: validate(is_integer(value) and value >= 0, value, key)
  end

  defp fetch_currency(map, key) do
    with {:ok, value} <- fetch_string(map, key), do: {:ok, String.upcase(value)}
  end

  defp fetch_timestamp(map, key) do
    with {:ok, value} <- fetch(map, key),
         true <- is_integer(value),
         {:ok, datetime} <- DateTime.from_unix(value) do
      {:ok, datetime}
    else
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_string(map, key) do
    case map do
      %{^key => nil} -> {:ok, nil}
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      %{} -> {:ok, nil}
    end
  end

  defp validate(true, value, _key), do: {:ok, value}
  defp validate(false, _value, key), do: {:error, {:invalid_field, key}}
end
