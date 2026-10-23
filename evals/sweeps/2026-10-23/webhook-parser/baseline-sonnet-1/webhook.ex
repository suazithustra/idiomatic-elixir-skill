defmodule Payments.Webhook.Money do
  @moduledoc "An amount in minor units (for example cents) with an upper-case ISO 4217 currency code."

  @enforce_keys [:amount, :currency]
  defstruct [:amount, :currency]

  @type t :: %__MODULE__{amount: non_neg_integer(), currency: String.t()}
end

defmodule Payments.Webhook.PaymentSucceeded do
  @moduledoc "A payment completed."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :money]
  defstruct [:event_id, :occurred_at, :payment_id, :money, :customer_email]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          money: Payments.Webhook.Money.t(),
          customer_email: String.t() | nil
        }
end

defmodule Payments.Webhook.PaymentFailed do
  @moduledoc "A payment attempt failed. `failure_reason` is nil when the provider gave none."

  @enforce_keys [:event_id, :occurred_at, :payment_id, :money]
  defstruct [:event_id, :occurred_at, :payment_id, :money, :customer_email, :failure_reason]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          payment_id: String.t(),
          money: Payments.Webhook.Money.t(),
          customer_email: String.t() | nil,
          failure_reason: String.t() | nil
        }
end

defmodule Payments.Webhook.RefundCreated do
  @moduledoc "A refund was created against a payment."

  @enforce_keys [:event_id, :occurred_at, :refund_id, :payment_id, :money]
  defstruct [:event_id, :occurred_at, :refund_id, :payment_id, :money]

  @type t :: %__MODULE__{
          event_id: String.t(),
          occurred_at: DateTime.t(),
          refund_id: String.t(),
          payment_id: String.t(),
          money: Payments.Webhook.Money.t()
        }
end

defmodule Payments.Webhook do
  @moduledoc """
  Turns a decoded webhook payload (string-keyed map) into a typed event struct.

  Returns `{:ok, event}` for the supported event types, `{:error, {:unsupported_type, type}}`
  for valid payloads of a type we ignore, and `{:error, reason}` for malformed payloads.
  """

  alias Payments.Webhook.{Money, PaymentFailed, PaymentSucceeded, RefundCreated}

  @type event :: PaymentSucceeded.t() | PaymentFailed.t() | RefundCreated.t()

  @type error ::
          {:unsupported_type, String.t()}
          | {:missing_field, String.t()}
          | {:invalid_field, String.t()}
          | :invalid_payload

  @spec parse(term()) :: {:ok, event()} | {:error, error()}
  def parse(%{"id" => id, "type" => type, "created" => created, "data" => data})
      when is_map(data) do
    with {:ok, id} <- fetch_string(%{"id" => id}, "id"),
         {:ok, occurred_at} <- parse_timestamp(created) do
      build(type, %{event_id: id, occurred_at: occurred_at}, data)
    end
  end

  def parse(payload) when is_map(payload) do
    case Enum.find(["id", "type", "created", "data"], &(not is_map_key(payload, &1))) do
      nil -> {:error, {:invalid_field, "data"}}
      key -> {:error, {:missing_field, key}}
    end
  end

  def parse(_payload), do: {:error, :invalid_payload}

  defp build("payment.succeeded", base, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, money} <- parse_money(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email") do
      {:ok, struct!(PaymentSucceeded, [payment_id: payment_id, money: money, customer_email: email] ++ Map.to_list(base))}
    end
  end

  defp build("payment.failed", base, data) do
    with {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, money} <- parse_money(data),
         {:ok, email} <- fetch_optional_string(data, "customer_email"),
         {:ok, reason} <- fetch_optional_string(data, "failure_reason") do
      fields = [payment_id: payment_id, money: money, customer_email: email, failure_reason: reason]
      {:ok, struct!(PaymentFailed, fields ++ Map.to_list(base))}
    end
  end

  defp build("refund.created", base, data) do
    with {:ok, refund_id} <- fetch_string(data, "refund_id"),
         {:ok, payment_id} <- fetch_string(data, "payment_id"),
         {:ok, money} <- parse_money(data) do
      fields = [refund_id: refund_id, payment_id: payment_id, money: money]
      {:ok, struct!(RefundCreated, fields ++ Map.to_list(base))}
    end
  end

  defp build(type, _base, _data) when is_binary(type), do: {:error, {:unsupported_type, type}}
  defp build(_type, _base, _data), do: {:error, {:invalid_field, "type"}}

  defp parse_money(data) do
    with {:ok, amount} <- fetch_amount(data),
         {:ok, currency} <- fetch_string(data, "currency") do
      {:ok, %Money{amount: amount, currency: String.upcase(currency)}}
    end
  end

  defp fetch_amount(%{"amount" => amount}) when is_integer(amount) and amount >= 0,
    do: {:ok, amount}

  defp fetch_amount(%{"amount" => _}), do: {:error, {:invalid_field, "amount"}}
  defp fetch_amount(_data), do: {:error, {:missing_field, "amount"}}

  defp fetch_string(data, key) do
    case data do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp fetch_optional_string(data, key) do
    case data do
      %{^key => nil} -> {:ok, nil}
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _} -> {:error, {:invalid_field, key}}
      _ -> {:ok, nil}
    end
  end

  defp parse_timestamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _} -> {:error, {:invalid_field, "created"}}
    end
  end

  defp parse_timestamp(_), do: {:error, {:invalid_field, "created"}}
end
